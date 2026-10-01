<#
.SYNOPSIS
    Read-only probe for the opencode desktop (Windows) app.asar.

.DESCRIPTION
    Answers three questions about a packaged opencode desktop install, without
    ever writing to the target file or its directory:

      1. Is the bundle minified?  (decides whether a literal string patch is even
         possible - minified output renames local variables, so the old needle
         "if (layoutUpgrade()) return true;" would not exist verbatim)
      2. Which layout-related strings are still present, how many times, and at
         which byte offsets?  (a patch is only safe when the count is exactly 1)
      3. Which file inside the ASAR contains each hit, at which line/column?

    Nothing is modified. No temporary files are created unless you pass
    -SelfTest, which writes and deletes one scratch file under $env:TEMP.

.PARAMETER Path
    Folder that contains app.asar, the app.asar file itself, or a folder that
    contains resources\app.asar. If omitted, you are prompted; if the prompt is
    left blank, known install locations are auto-detected.

.PARAMETER Context
    Characters of context to print around each hit. Default 400.

.PARAMETER SelfTest
    Verify the search / offset / context logic against known answers using a
    synthetic scratch file, then delete it. Run this first to prove the tool
    works before pointing it at a real app.asar.

.PARAMETER ExtraNeedle
    Additional literal patterns to look for.

.PARAMETER ExtractOwner
    Folder to export the files that contain needle hits into. Use it when you
    want to hand those files to someone else: it turns a 140MB ASAR into a few
    small files. The ASAR is only ever read.

.EXAMPLE
    .\probe-opencode-layout.ps1 -SelfTest

.EXAMPLE
    .\probe-opencode-layout.ps1 -Path "$env:LOCALAPPDATA\Programs\@opencode-aidesktop"

.NOTES
    Console output is intentionally ASCII-only so it cannot turn into mojibake
    on a legacy Windows console with a raster font or a non-UTF8 code page.
#>
[CmdletBinding()]
param(
    [string]   $Path,
    [int]      $Context = 400,
    [switch]   $SelfTest,
    [string[]] $ExtraNeedle,
    [string]   $ExtractOwner
)

$ErrorActionPreference = 'Stop'

# ISO-8859-1 maps bytes 0x00-0xFF to U+0000-U+00FF one to one, so a character
# index into the decoded string is also the byte offset into the file. That is
# what makes the reported offsets directly usable by a patcher.
# ('Encoding::Latin1' does not exist on .NET Framework, so use the name.)
$script:LatEnc = [System.Text.Encoding]::GetEncoding('ISO-8859-1')

# Single-entry cache for Get-LineColumn, so repeated hits inside the same
# renderer chunk do not re-decode a multi-megabyte string.
$script:CachedFileStart = -1
$script:CachedFileText = $null
$script:SelfTestFailures = 0

# ---------------------------------------------------------------- primitives

function Write-Title {
    param([string] $Text)
    Write-Host ''
    Write-Host ('== ' + $Text + ' ' + ('=' * [Math]::Max(3, 66 - $Text.Length)))
}

function Get-Latin1Text {
    param([string] $FilePath)
    return $script:LatEnc.GetString([System.IO.File]::ReadAllBytes($FilePath))
}

function Get-Latin1TextFromBytes {
    param([byte[]] $Bytes)
    return $script:LatEnc.GetString($Bytes)
}

function Find-Occurrences {
    <#  Returns the List[int] of every start offset. Note the leading comma:
        without it PowerShell would unroll the List into the pipeline.  #>
    param([string] $Text, [string] $Needle, [int] $Limit = 200)
    $hits = New-Object 'System.Collections.Generic.List[int]'
    if ([string]::IsNullOrEmpty($Needle)) { return , $hits }
    $start = 0
    while ($hits.Count -lt $Limit) {
        $idx = $Text.IndexOf($Needle, $start, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { break }
        $hits.Add($idx)
        $start = $idx + 1
    }
    return , $hits
}

function Get-HitContext {
    <#  Splits the neighbourhood into before / hit / after so the caller can
        highlight the match without re-searching.  #>
    param([string] $Text, [int] $Index, [int] $NeedleLength, [int] $Pad)
    $start = $Index - $Pad
    if ($start -lt 0) { $start = 0 }
    $end = $Index + $NeedleLength + $Pad
    if ($end -gt $Text.Length) { $end = $Text.Length }
    $slice = $Text.Substring($start, $end - $start)
    $slice = $slice.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')

    $rel = $Index - $start
    $hitLen = [Math]::Min($NeedleLength, $slice.Length - $rel)
    $before = ''
    if ($rel -gt 0) { $before = $slice.Substring(0, $rel) }
    $hit = $slice.Substring($rel, $hitLen)
    $afterIdx = $rel + $hitLen
    $after = ''
    if ($afterIdx -lt $slice.Length) { $after = $slice.Substring($afterIdx) }

    return [pscustomobject]@{ Before = $before; Hit = $hit; After = $after }
}

function Get-FormatHint {
    <#  Cheap heuristic: minified bundles have very long lines and almost no
        "if (" / ") {" occurrences, because the printer strips the spaces.  #>
    param([string] $Text)
    $sampleLen = [Math]::Min($Text.Length, 4 * 1024 * 1024)
    $sample = $Text.Substring(0, $sampleLen)
    $newlines = [regex]::Matches($sample, "\n").Count
    $ifSpaced = [regex]::Matches($sample, "\bif \(").Count
    $braceSpaced = [regex]::Matches($sample, "\) \{").Count
    $avgLine = [double] $sampleLen / [double] ($newlines + 1)

    $verdict = 'unknown'
    if ($ifSpaced -gt 50 -and $avgLine -lt 300) { $verdict = 'NOT minified (readable, literal patching possible)' }
    elseif ($ifSpaced -le 5 -and $avgLine -ge 300) { $verdict = 'LIKELY MINIFIED (identifiers renamed, literal patching fragile)' }

    return [pscustomobject]@{
        SampleBytes  = $sampleLen
        Newlines     = $newlines
        AvgLineLen   = [Math]::Round($avgLine, 1)
        IfSpaced     = $ifSpaced
        BraceSpaced  = $braceSpaced
        Verdict      = $verdict
    }
}

# ------------------------------------------------------------------ ASAR map

function Read-AsarIndex {
    <#  Minimal ASAR header reader. Layout is:
          u32[0] = 4, u32[4] = headerSize, u32[8] = headerSize-4,
          u32[12] = json byte length, then the JSON at offset 16.
        Returns $null when the file is not a recognisable ASAR.  #>
    param([byte[]] $Bytes)

    if ($Bytes.Length -lt 16) { return $null }
    if ([System.BitConverter]::ToUInt32($Bytes, 0) -ne 4) { return $null }

    $headerSize = [System.BitConverter]::ToUInt32($Bytes, 4)
    $jsonLen = [System.BitConverter]::ToUInt32($Bytes, 12)
    $dataStart = 8 + [int64] $headerSize
    if ($jsonLen -le 0 -or (16 + $jsonLen) -gt $Bytes.Length) { return $null }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString($Bytes, 16, $jsonLen)
        $hdr = $json | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($null -eq $hdr.files) { return $null }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Stack'
    $stack.Push(@{ Node = $hdr.files; Prefix = '' })
    while ($stack.Count -gt 0) {
        $top = $stack.Pop()
        $node = $top.Node
        $prefix = $top.Prefix
        foreach ($prop in $node.PSObject.Properties) {
            $child = $prop.Value
            $childPath = if ($prefix -eq '') { '/' + $prop.Name } else { $prefix + '/' + $prop.Name }
            if ($null -ne $child.files) {
                $stack.Push(@{ Node = $child.files; Prefix = $childPath })
            } else {
                $offset = -1
                if ($null -ne $child.offset) { $offset = [int64] $child.offset }
                $entries.Add([pscustomobject]@{
                    Path     = $childPath
                    Size     = [int64] $(if ($null -ne $child.size) { $child.size } else { 0 })
                    Offset   = $offset
                    Unpacked = [bool] $(if ($null -ne $child.unpacked) { $child.unpacked } else { $false })
                })
            }
        }
    }
    return [pscustomobject]@{ DataStart = $dataStart; Entries = $entries }
}

function Find-AsarOwner {
    <#  Which packed file inside the ASAR contains this absolute byte offset?  #>
    param($Index, [int64] $Offset)
    foreach ($e in $Index.Entries) {
        if ($e.Unpacked -or $e.Offset -lt 0) { continue }
        $start = $Index.DataStart + $e.Offset
        if ($Offset -ge $start -and $Offset -lt ($start + $e.Size)) {
            return [pscustomobject]@{ Entry = $e; FileStart = $start; InFile = $Offset - $start }
        }
    }
    return $null
}

function Export-OwningFiles {
    <#  Copies the files that contain needle hits out of the ASAR, so they can be
        inspected without shipping a 140MB archive around. Writes ONLY into
        $OutDir and never touches the ASAR itself.  #>
    param($Index, [byte[]] $Bytes, [string] $OutDir, $OwnerList)

    if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path (Get-Location).Path 'probe-extract' }
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $resolvedDir = (Resolve-Path -LiteralPath $OutDir).Path

    $total = 0
    foreach ($e in $OwnerList) {
        if ($e.Unpacked -or $e.Offset -lt 0) { continue }
        $len = [int] $e.Size
        if ($len -le 0) { continue }
        $start = [int] ($Index.DataStart + [int64] $e.Offset)
        if (($start + $len) -gt $Bytes.Length) {
            Write-Host ('  skip (out of range): ' + $e.Path)
            continue
        }
        $flat = ($e.Path -replace '^/', '') -replace '[\\/]', '__'
        $dest = Join-Path $resolvedDir $flat
        $chunk = New-Object 'byte[]' $len
        [System.Array]::Copy($Bytes, $start, $chunk, 0, $len)
        [System.IO.File]::WriteAllBytes($dest, $chunk)
        Write-Host ('  ' + [Math]::Round($len / 1KB, 1) + ' KB -> ' + $dest)
        $total += $len
    }
    Write-Host ('  total extracted: ' + [Math]::Round($total / 1MB, 2) + ' MB into ' + $resolvedDir)
    return $total
}

function Get-LineColumn {
    <#  Byte offset -> 1-based line / column, by decoding only the owning file
        (a few MB) and letting the regex engine count the newlines natively.
        Single-entry cache: most hits live in the same renderer chunk.  #>
    param([byte[]] $Bytes, [int64] $FileStart, [int64] $InFile, [int64] $Size)

    $available = [int64] $Bytes.Length - $FileStart
    if ($available -le 0) { return $null }
    $take = [Math]::Min([int64] $Size, $available)
    if ($take -le 0 -or $InFile -gt $take) { return $null }

    if ($script:CachedFileStart -ne $FileStart) {
        $script:CachedFileStart = $FileStart
        $script:CachedFileText = $script:LatEnc.GetString($Bytes, [int] $FileStart, [int] $take)
    }
    $slice = $script:CachedFileText

    $prefix = $slice.Substring(0, [int] $InFile)
    $line = [regex]::Matches($prefix, "\n").Count + 1
    $lastNl = $prefix.LastIndexOf("`n")
    $col = $InFile - $lastNl
    return [pscustomobject]@{ Line = $line; Column = $col }
}

# ------------------------------------------------------------ path discovery

function Get-DefaultCandidates {
    $out = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { return , $out }

    $roots = New-Object 'System.Collections.Generic.List[string]'
    $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop'))
    $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\opencode'))
    $roots.Add((Join-Path $env:LOCALAPPDATA 'opencode'))
    $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\OpenCode'))
    foreach ($r in $roots) {
        $out.Add((Join-Path $r 'resources\app.asar'))
        $out.Add((Join-Path $r 'app.asar'))
    }
    $programs = Join-Path $env:LOCALAPPDATA 'Programs'
    if (Test-Path -LiteralPath $programs -PathType Container) {
        # -like is case-insensitive by default, so one pattern covers both cases.
        foreach ($dir in (Get-ChildItem -LiteralPath $programs -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($dir.Name -like '*opencode*') {
                $out.Add((Join-Path $dir.FullName 'resources\app.asar'))
            }
        }
    }
    return , $out
}

function Resolve-AsarPath {
    <#  Accepts an app.asar file, a folder containing app.asar, or a folder
        containing resources\app.asar. Returns a list of resolved files.  #>
    param([string] $InputPath)

    $found = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return , $found }

    $p = $InputPath.Trim().Trim('"').Trim("'")
    if (-not (Test-Path -LiteralPath $p)) { return , $found }

    $item = Get-Item -LiteralPath $p -Force
    if (-not $item.PSIsContainer) {
        if ($item.Name -eq 'app.asar') { $found.Add($item.FullName) }
        return , $found
    }

    $candidates = @(
        (Join-Path $item.FullName 'resources\app.asar'),
        (Join-Path $item.FullName 'app.asar')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $found.Add((Get-Item -LiteralPath $c).FullName) }
    }
    return , $found
}

function Repair-InstallPath {
    <#  Repairs the one paste/typing accident that actually happens in practice:
        the "\" in front of a scoped package name gets dropped, turning
        "...\Programs\@opencode-aidesktop" into "...\Programs@opencode-aidesktop".
        Only call this AFTER the original path failed to resolve, so a legitimate
        "@" inside a folder name can never be mangled into something worse.  #>
    param([string] $InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $InputPath }
    # Zero-width lookahead on purpose: the lookahead consumes nothing, so only a
    # separator gets inserted. Matching "@" itself would delete the character.
    $fixed = [regex]::Replace($InputPath, '(?<=[^\\/])(?=@)', '\')
    return $fixed
}

# ------------------------------------------------------------------ self test

function Invoke-SelfTest {
    Write-Title 'SELF TEST'
    $tmp = Join-Path $env:TEMP ('oc_probe_selftest_' + [guid]::NewGuid().ToString('N') + '.bin')
    $script:SelfTestFailures = 0

    function Assert-That {
        param([string] $Name, [bool] $Ok, [string] $Detail)
        if ($Ok) {
            Write-Host ('  [PASS] ' + $Name)
        } else {
            Write-Host ('  [FAIL] ' + $Name + '  ->  ' + $Detail)
            $script:SelfTestFailures = $script:SelfTestFailures + 1
        }
    }

    # 1. the 1:1 byte/char assumption the whole offset story depends on
    $all = ''
    for ($i = 0; $i -lt 256; $i++) { $all = $all + [char] $i }
    $round = $script:LatEnc.GetBytes($all)
    Assert-That -Name 'ISO-8859-1 is byte<->char 1:1' -Ok ($round.Length -eq 256) -Detail ('expected 256 bytes, got ' + $round.Length)

    # 2. offsets survive a file round trip
    $needle = 'if (layoutUpgrade()) return true;'
    $content = 'PREFIX-BYTES' + $needle + '-SUFFIX-BYTES'
    $content = $content + ('x' * 500) + $needle + 'TAIL'
    $bytes = $script:LatEnc.GetBytes($content)
    [System.IO.File]::WriteAllBytes($tmp, $bytes)

    $text = Get-Latin1Text $tmp
    Assert-That -Name 'decoded length equals byte length' -Ok ($text.Length -eq $bytes.Length) -Detail ('text=' + $text.Length + ' bytes=' + $bytes.Length)
    Assert-That -Name 'round trip is lossless' -Ok ($text -eq $content) -Detail 'decoded text differs from what was written'

    $hits = Find-Occurrences -Text $text -Needle $needle
    Assert-That -Name 'finds both occurrences' -Ok ($hits.Count -eq 2) -Detail ('expected 2, got ' + $hits.Count)

    $expectedFirst = $content.IndexOf($needle, [System.StringComparison]::Ordinal)
    $expectedSecond = $content.IndexOf($needle, $expectedFirst + 1, [System.StringComparison]::Ordinal)
    $offsetsOk = ($hits.Count -eq 2) -and ($hits[0] -eq $expectedFirst) -and ($hits[1] -eq $expectedSecond)
    Assert-That -Name 'offsets are exact' -Ok $offsetsOk -Detail ('got ' + $hits[0] + ',' + $hits[1] + ' expected ' + $expectedFirst + ',' + $expectedSecond)

    $ctx = Get-HitContext -Text $text -Index $hits[0] -NeedleLength $needle.Length -Pad 12
    Assert-That -Name 'context marks the hit' -Ok ($ctx.Hit -eq $needle) -Detail ('hit was ' + $ctx.Hit)
    Assert-That -Name 'context keeps the left neighbour' -Ok ($ctx.Before.EndsWith('PREFIX-BYTES')) -Detail ('before was ' + $ctx.Before)
    Assert-That -Name 'context keeps the right neighbour' -Ok ($ctx.After.StartsWith('-SUFFIX-BYTES')) -Detail ('after was ' + $ctx.After)

    # 3. equal-length patch arithmetic for both candidate targets
    $t1 = 'if (layoutUpgrade()) return true;'
    $r1 = 'return false;'
    $n1 = $r1 + (' ' * ($t1.Length - $r1.Length))
    Assert-That -Name 'old needle pads to equal length' -Ok ($n1.Length -eq $t1.Length) -Detail ('target=' + $t1.Length + ' replacement=' + $n1.Length)

    $t2 = '2026, 8, 14'
    $r2 = '2099, 8, 14'
    Assert-That -Name 'sunset needle is equal length' -Ok ($t2.Length -eq $r2.Length) -Detail ('target=' + $t2.Length + ' replacement=' + $r2.Length)

    # 3b. simulate the old script's patch, then confirm the probe can DETECT it.
    # This is what makes "already patched" a positive finding rather than a guess.
    $residue = 'return false;' + (' ' * ($t1.Length - $r1.Length))
    Assert-That -Name 'residue is 33 bytes' -Ok ($residue.Length -eq 33) -Detail ('residue=' + $residue.Length)
    $patched = [System.Text.Encoding]::ASCII.GetBytes($residue)
    $copy = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($b in $bytes) { $copy.Add($b) }
    for ($i = 0; $i -lt $patched.Length; $i++) { $copy[$expectedFirst + $i] = $patched[$i] }
    $patchedText = Get-Latin1TextFromBytes $copy.ToArray()
    Assert-That -Name 'patched file is the same length' -Ok ($patchedText.Length -eq $bytes.Length) -Detail ('before=' + $bytes.Length + ' after=' + $patchedText.Length)
    $residueHits = Find-Occurrences -Text $patchedText -Needle $residue
    Assert-That -Name 'patched file is detected as patched' -Ok ($residueHits.Count -eq 1 -and $residueHits[0] -eq $expectedFirst) -Detail ('hits=' + $residueHits.Count)
    $goneHits = Find-Occurrences -Text $patchedText -Needle $t1
    # The fixture deliberately holds the needle twice, so after patching the first
    # occurrence exactly one must remain, at the original second offset.
    Assert-That -Name 'only the intended occurrence was changed' -Ok ($goneHits.Count -eq 1 -and $goneHits[0] -eq $expectedSecond) -Detail ('hits=' + $goneHits.Count + ' remaining at ' + $(if ($goneHits.Count -gt 0) { $goneHits[0] } else { 'n/a' }) + ', expected ' + $expectedSecond)

    # 4. a missing needle must report zero hits rather than blow up
    $none = Find-Occurrences -Text $text -Needle 'this-string-is-absent'
    Assert-That -Name 'absent needle yields zero hits' -Ok ($none.Count -eq 0) -Detail ('got ' + $none.Count)

    # 5. line / column mapping
    $lc = Get-LineColumn -Bytes $bytes -FileStart 0 -InFile $expectedFirst -Size $bytes.Length
    $lcOk = ($null -ne $lc) -and ($lc.Line -eq 1) -and ($lc.Column -eq ($expectedFirst + 1))
    Assert-That -Name 'line and column resolve to line 1' -Ok $lcOk -Detail $(if ($null -eq $lc) { 'returned null' } else { 'line=' + $lc.Line + ' column=' + $lc.Column })

    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Assert-That -Name 'scratch file removed' -Ok (-not (Test-Path -LiteralPath $tmp)) -Detail 'still on disk'

    if ($script:SelfTestFailures -eq 0) {
        Write-Host ''
        Write-Host '  Self test passed. The search and offset logic is trustworthy.'
    } else {
        Write-Host ''
        Write-Host ('  Self test FAILED (' + $script:SelfTestFailures + ' problem(s)). Do not trust results on a real file.')
    }
}

# ------------------------------------------------------------------ needle set

function Get-DefaultNeedles {
    <#  Keys are stable identifiers so the summary can look entries up by name
        instead of by pattern text.  #>
    return @(
        [pscustomobject]@{ Key = 'residue';Name = 'old patch residue'; Pattern = ('return false;' + (' ' * 20)); Role = 'the 33 bytes the old script writes. A hit means this asar is ALREADY patched' }
        [pscustomobject]@{ Key = 'oldexact'; Name = 'old needle (exact)'; Pattern = 'if (layoutUpgrade()) return true;'; Role = 'what the current script looks for' }
        [pscustomobject]@{ Key = 'oldloose'; Name = 'old needle (no semi)'; Pattern = 'if (layoutUpgrade()) return true'; Role = 'same, tolerant of the semicolon' }
        [pscustomobject]@{ Key = 'layoutUpgrade'; Name = 'layoutUpgrade'; Pattern = 'layoutUpgrade'; Role = 'identifier: definition + its uses' }
        [pscustomobject]@{ Key = 'retired'; Name = 'oldInterfaceRetired'; Pattern = 'oldInterfaceRetired'; Role = 'DECISIVE: present => this build has the sunset gate, so forcing layoutUpgrade false cannot restore the old layout' }
        [pscustomobject]@{ Key = 'resolve'; Name = 'resolveNewLayoutDesigns'; Pattern = 'resolveNewLayoutDesigns'; Role = 'the retired short-circuit function' }
        [pscustomobject]@{ Key = 'sunsetname'; Name = 'oldInterfaceSunset'; Pattern = 'oldInterfaceSunset'; Role = 'the sunset date constant' }
        [pscustomobject]@{ Key = 'sunsetspaced'; Name = 'sunset date (spaced)'; Pattern = '2026, 8, 14'; Role = 'patch target: -> 2099, 8, 14 (same 11 bytes)' }
        [pscustomobject]@{ Key = 'sunsettight'; Name = 'sunset date (tight)'; Pattern = '2026,8,14'; Role = 'same, if a build ever minifies' }
        [pscustomobject]@{ Key = 'cutoff'; Name = 'newLayoutDesignsUpgradeCutoff'; Pattern = 'newLayoutDesignsUpgradeCutoff'; Role = 'version cutoff 1.17.19' }
        [pscustomobject]@{ Key = 'legacydefault'; Name = 'legacyNewLayoutDesignsDefault'; Pattern = 'legacyNewLayoutDesignsDefault'; Role = 'default used before a preference exists' }
        [pscustomobject]@{ Key = 'newdefault'; Name = 'newLayoutDesignsDefault'; Pattern = 'newLayoutDesignsDefault'; Role = 'default used after retirement' }
        [pscustomobject]@{ Key = 'newLayoutDesigns'; Name = 'newLayoutDesigns'; Pattern = 'newLayoutDesigns'; Role = 'is the legacy layout still shipped?' }
        [pscustomobject]@{ Key = 'createMemo'; Name = 'createMemo'; Pattern = 'createMemo'; Role = 'bundler marker for minify detection' }
    )
}

# ----------------------------------------------------------------------- main

try {
    if ($SelfTest) {
        Invoke-SelfTest
        return
    }

    Write-Host 'opencode desktop app.asar probe  --  READ ONLY, nothing is modified'
    Write-Title 'TARGET'

    $resolved = New-Object 'System.Collections.Generic.List[string]'
    $source = ''
    $supplied = ''

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $answer = Read-Host 'Enter the opencode install folder or the app.asar path (blank = auto-detect)'
        $Path = $answer
    }
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $supplied = $Path.Trim() }

    if (-not [string]::IsNullOrWhiteSpace($supplied)) {
        foreach ($r in (Resolve-AsarPath $supplied)) { $resolved.Add($r) }
        if ($resolved.Count -gt 0) {
            $source = 'the path you supplied'
        } else {
            $repaired = Repair-InstallPath $supplied
            if ($repaired -ne $supplied) {
                foreach ($r in (Resolve-AsarPath $repaired)) { $resolved.Add($r) }
                if ($resolved.Count -gt 0) { $source = 'your path, with a missing "\" restored before "@"' }
            }
        }
    }

    # Last resort, and the reason a typo can never dead-end this script: fall
    # back to the known install locations instead of giving up.
    if ($resolved.Count -eq 0) {
        foreach ($c in (Get-DefaultCandidates)) {
            if (Test-Path -LiteralPath $c -PathType Leaf) { $resolved.Add((Get-Item -LiteralPath $c).FullName) }
        }
        if ($resolved.Count -gt 0) { $source = 'auto-detected known install locations' }
    }

    if ($resolved.Count -eq 0) {
        Write-Host ('Could not find app.asar. Last path tried: ' + $supplied)
        Write-Host ''
        Write-Host 'Pass the install folder (the one containing resources), or the app.asar file itself.'
        Write-Host 'Or just press Enter at the prompt and let auto-detect do it.'
        Write-Host ''
        Write-Host 'Known locations (* = exists right now):'
        foreach ($c in (Get-DefaultCandidates)) {
            $mark = '  '
            if (Test-Path -LiteralPath $c -PathType Leaf) { $mark = '* ' }
            Write-Host ($mark + $c)
        }
        return
    }

    Write-Host ('  resolved by : ' + $source)
    if ($source -notlike 'the path you supplied' -and -not [string]::IsNullOrWhiteSpace($supplied)) {
        Write-Host ('  you typed   : ' + $supplied)
        Write-Host '  (that path does not exist, so it was ignored)'
    }

    $asar = $resolved[0]
    foreach ($extra in $resolved) {
        if ($extra -ne $asar) { Write-Host ('  also found: ' + $extra) }
    }

    $fi = Get-Item -LiteralPath $asar
    Write-Host ('  path       : ' + $fi.FullName)
    Write-Host ('  size       : ' + $fi.Length + ' bytes (' + [Math]::Round($fi.Length / 1MB, 1) + ' MB)')
    Write-Host ('  modified   : ' + $fi.LastWriteTime)
    try { Write-Host ('  sha256     : ' + (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash) } catch { Write-Host '  sha256     : (unavailable)' }
    Write-Host ('  parent dir : ' + $fi.DirectoryName)
    foreach ($sibling in @('app.asar.unpacked', 'app', 'app-update.yml')) {
        $sp = Join-Path $fi.DirectoryName $sibling
        if (Test-Path -LiteralPath $sp) {
            $kind = if ((Get-Item -LiteralPath $sp).PSIsContainer) { 'DIR ' } else { 'FILE' }
            Write-Host ('  sibling    : ' + $kind + ' ' + $sibling)
        }
    }

    if ($fi.Length -gt 400MB) {
        Write-Host ''
        Write-Host 'WARNING: file is larger than 400MB; decoding it into a string needs a lot of RAM.'
    }

    Write-Title 'BUNDLE SHAPE'
    $bytes = [System.IO.File]::ReadAllBytes($asar)
    # Decode from the buffer we already hold; re-reading a 140MB file twice is
    # a needless second allocation.
    $text = $script:LatEnc.GetString($bytes)
    $hint = Get-FormatHint $text
    Write-Host ('  decoded chars      : ' + $text.Length + '  (byte-identical mapping: ' + ($text.Length -eq $bytes.Length) + ')')
    Write-Host ('  sample             : ' + $hint.SampleBytes + ' bytes')
    Write-Host ('  newlines in sample : ' + $hint.Newlines)
    Write-Host ('  avg line length    : ' + $hint.AvgLineLen)
    Write-Host ('  "if (" occurrences : ' + $hint.IfSpaced)
    Write-Host ('  ") {" occurrences  : ' + $hint.BraceSpaced)
    Write-Host ('  verdict            : ' + $hint.Verdict)

    $index = Read-AsarIndex $bytes
    $mapCount = -1
    $jsCount = -1
    if ($null -ne $index) {
        Write-Host ('  asar entries       : ' + $index.Entries.Count + ' (data starts at byte ' + $index.DataStart + ')')
        $packed = 0
        foreach ($e in $index.Entries) { if (-not $e.Unpacked) { $packed++ } }
        $jsCount = 0
        $mapCount = 0
        foreach ($e in $index.Entries) {
            if ($e.Path.EndsWith('.js')) { $jsCount++ }
            if ($e.Path.EndsWith('.map')) { $mapCount++ }
        }
        Write-Host ('  packed / unpacked  : ' + $packed + ' / ' + ($index.Entries.Count - $packed))
        Write-Host ('  .js / .map inside  : ' + $jsCount + ' / ' + $mapCount)
        if ($mapCount -gt 0) {
            Write-Host '  NOTE: sourcemap files are bundled. If they carried sourcesContent, every'
            Write-Host '        needle below would report extra hits from the .map copies.'
        }
    } else {
        Write-Host '  asar header        : not recognised (probe still works, offsets are file-absolute)'
    }

    Write-Title 'NEEDLE SCAN'
    $needles = Get-DefaultNeedles
    if ($null -ne $ExtraNeedle -and $ExtraNeedle.Count -gt 0) {
        foreach ($x in $ExtraNeedle) {
            $needles = $needles + [pscustomobject]@{ Name = 'extra'; Pattern = $x; Role = 'user supplied' }
        }
    }

    $summary = New-Object 'System.Collections.Generic.List[object]'
    $ownerSeen = @{}
    $ownerList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($n in $needles) {
        $hits = Find-Occurrences -Text $text -Needle $n.Pattern
        $label = 'MISS'
        if ($hits.Count -eq 1) { $label = 'UNIQUE' }
        elseif ($hits.Count -gt 1) { $label = 'MULTI ' }
        Write-Host ''
        Write-Host ('  [' + $label + '] ' + $n.Name + '  --  "' + $n.Pattern + '"')
        Write-Host ('      role   : ' + $n.Role)
        Write-Host ('      hits   : ' + $hits.Count + '   offsets: ' + (($hits | Select-Object -First 8) -join ', ') + $(if ($hits.Count -gt 8) { ', ...' } else { '' }))
        $summary.Add([pscustomobject]@{ Key = $n.Key; Name = $n.Name; Pattern = $n.Pattern; Count = $hits.Count })

        if ($hits.Count -eq 0) { continue }

        $show = [Math]::Min($hits.Count, 3)
        for ($i = 0; $i -lt $show; $i++) {
            $off = $hits[$i]
            $ctx = Get-HitContext -Text $text -Index $off -NeedleLength $n.Pattern.Length -Pad $Context
            Write-Host ('      --- hit ' + ($i + 1) + ' @ byte ' + $off + ' ---')
            if ($null -ne $index) {
                $owner = Find-AsarOwner -Index $index -Offset $off
                if ($null -ne $owner) {
                    if (-not $ownerSeen.ContainsKey($owner.Entry.Path)) {
                        $ownerSeen[$owner.Entry.Path] = $true
                        $ownerList.Add($owner.Entry)
                    }
                    $lineTxt = ''
                    if ($i -eq 0) {
                        # Decoding the owning chunk is the expensive part, so only
                        # resolve line/column for the first hit of each needle.
                        $lc = Get-LineColumn -Bytes $bytes -FileStart $owner.FileStart -InFile $owner.InFile -Size $owner.Entry.Size
                        if ($null -ne $lc) { $lineTxt = ', line ' + $lc.Line + ', col ' + $lc.Column }
                    }
                    Write-Host ('      in file : ' + $owner.Entry.Path + ' (+' + $owner.InFile + ' bytes' + $lineTxt + ')')
                } else {
                    Write-Host '      in file : (not inside any packed entry)'
                }
            }
            Write-Host ('      context : ' + $ctx.Before + ' >>>' + $ctx.Hit + '<<<' + $ctx.After)
        }
        if ($hits.Count -gt $show) {
            Write-Host ('      (' + ($hits.Count - $show) + ' more hit(s) not shown)')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExtractOwner)) {
        Write-Title 'EXPORT'
        if ($ownerList.Count -eq 0) {
            Write-Host ' No hit could be located inside a packed file, so there is nothing to export.'
        } else {
            Write-Host (' Files containing hits: ' + $ownerList.Count)
            if ($null -eq $index) {
                Write-Host ' Cannot export: the ASAR index is unavailable, so offsets cannot be resolved.'
            } else {
                Write-Host 'The ASAR itself is only read. The files below are new files in the output folder.'
                $exported = Export-OwningFiles -Index $index -Bytes $bytes -OutDir $ExtractOwner -OwnerList $ownerList
                if ($exported -gt 0) {
                    Write-Host ''
                    Write-Host ' Send that folder over. The largest file is the interesting one: it holds the'
                    Write-Host ' layout code, so a few MB is enough to identify the build exactly.'
                }
            }
        }
    }

    Write-Title 'READING THE RESULT'
    function Get-Count {
        param([string] $Key)
        $row = $summary | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
        if ($null -eq $row) { return 0 }
        return $row.Count
    }

    $nResidue = Get-Count 'residue'
    $nOldExact = Get-Count 'oldexact'
    $nOldLoose = Get-Count 'oldloose'
    $nRetired = Get-Count 'retired'
    $nResolve = Get-Count 'resolve'
    $nSunset = Get-Count 'sunsetspaced'
    $nLegacy = Get-Count 'newLayoutDesigns'
    $nMemo = Get-Count 'createMemo'

    Write-Host (' bundle format                : ' + $hint.Verdict)
    Write-Host (' old patch residue (33 bytes) : ' + $nResidue + '   <- 0 = untouched, 1 = already patched')
    Write-Host (' old needle, with semicolon   : ' + $nOldExact)
    Write-Host (' old needle, no semicolon     : ' + $nOldLoose)
    Write-Host (' oldInterfaceRetired          : ' + $nRetired + '   <- 0 = this build has NO sunset gate')
    Write-Host (' sunset date "2026, 8, 14"    : ' + $nSunset)
    Write-Host (' legacy layout references     : ' + $nLegacy)
    Write-Host ''

    Write-Host ' PATCH STATE'
    if ($nResidue -ge 1) {
        Write-Host ' * This asar has ALREADY been patched by the old script. That is why the old'
        Write-Host '   needle reads 0 hits -- it was replaced, not removed.'
    } else {
        Write-Host ' * This asar has NOT been patched (no residue marker found).'
        if ($nOldExact -eq 1) {
            Write-Host '   The old script would find its needle exactly once and patch it.'
        } elseif ($nOldExact -eq 0 -and $nOldLoose -ge 1) {
            Write-Host '   The old script would find NOTHING and exit 0 while printing'
            Write-Host '   "maybe already locked" -- a silent no-op. Its needle carries a semicolon'
            Write-Host '   that this build does not have.'
        } elseif ($nOldExact -eq 0) {
            Write-Host '   The old needle is absent in both spellings; the guard was probably restructured.'
        } else {
            Write-Host ('   The old needle appears ' + $nOldExact + ' times; the old script refuses to run.')
        }
    }
    Write-Host ''

    Write-Host ' SUNSET GATE'
    if ($nRetired -ge 1 -or $nResolve -ge 1) {
        Write-Host ' * This build HAS the retirement mechanism (oldInterfaceRetired /'
        Write-Host '   resolveNewLayoutDesigns). Once the sunset date has passed, that mechanism'
        Write-Host '   forces the new layout no matter what layoutUpgrade returns, so forcing'
        Write-Host '   layoutUpgrade false -- what the old script does -- has NO effect.'
        if ($nSunset -eq 1) {
            Write-Host '   The only effective lever on such a build is the sunset date itself.'
        }
    } else {
        Write-Host ' * This build has NO retirement mechanism, so layoutUpgrade was the only gate --'
        Write-Host '   which is exactly why the old patch works here.'
        Write-Host '   WARNING: this is version-fragile. The moment an update ships the retirement'
        Write-Host '   mechanism, the same patch silently stops having any effect.'
    }
    Write-Host ''

    Write-Host ' OLD LAYOUT'
    if ($nLegacy -gt 0) {
        Write-Host (' * Still shipped (' + $nLegacy + ' references), so the old UI code has not been deleted.')
    } else {
        Write-Host ' * No references left. Upstream removed the old UI; no patch can bring it back.'
    }

    if ($nSunset -eq 1) {
        Write-Host ''
        Write-Host ' BEFORE PATCHING THE DATE, confirm the context line above reads exactly:'
        Write-Host '     const oldInterfaceSunset = new Date(2026, 8, 14);'
        Write-Host ' A lone unrelated hit would be patched just as silently, since "2099, 8, 14" is'
        Write-Host ' also 11 bytes.'
    }

    if ($nMemo -eq 0) {
        Write-Host ''
        Write-Host ' * "createMemo" has 0 hits, which suggests identifiers WERE renamed and this build'
        Write-Host '   may be minified. Re-check the verdict line above before trusting any offset.'
    }

    Write-Host ''
    Write-Host ' Reminder: the desktop app rewrites app.asar on every update, so any patch must be'
    Write-Host ' reapplied afterwards. Verify by restarting the app, not by re-running this probe.'
} catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message)
    Write-Host 'The target was not modified.'
}