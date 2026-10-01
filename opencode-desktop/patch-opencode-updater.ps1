<#
.SYNOPSIS
    Disables the OpenCode desktop auto-updater by patching one constant.

.DESCRIPTION
    The desktop app has no setting, no environment variable and no config key
    that turns the updater off. The whole feature hangs off one compile-time
    constant in the Electron main bundle:

        const raw = "prod";
        const CHANNEL = raw;
        const UPDATER_ENABLED = app.isPackaged && CHANNEL !== "dev";

    which comes from packages/desktop/src/main/constants.ts, where
    import.meta.env.OPENCODE_CHANNEL is inlined as "prod" at build time.

    UPDATER_ENABLED has exactly two consumers:

      1. createUpdaterController({ enabled: UPDATER_ENABLED })
         The controller's first statement is
             if (!input.enabled) return Promise.resolve(state)
         so a false value short-circuits every check. autoUpdater
         .checkForUpdates() is never reached and not a single HTTP request
         leaves the machine.

      2. the macOS "Check for Updates" menu item's enabled flag.
         Irrelevant on Windows.

    Everything downstream follows from that one boolean:

      - startup check (void updater.start()) becomes a no-op
      - the 10 minute interval (setInterval(check, 10 * 60 * 1e3)) becomes a
        no-op
      - Settings > General > Updates > "Check for updates" renders disabled,
        because updaterAction() returns no run handler for status "disabled"
      - showUpdaterDialog() returns before its first dialog, so no error or
        info box appears
      - no release poll, no ~126 MB download, no pending installer

    Note that autoDownload and autoInstallOnAppQuit were already false in the
    app, but the app's own controller calls downloadUpdate() as soon as it sees
    a newer release. So without this patch the download happens silently and
    only the final install waits for a click. This patch removes the download
    too.

    Do NOT patch "prod" to "dev" instead. CHANNEL is also used for APP_IDS,
    TAURI_APP_IDS, app.setName, app.setAppUserModelId and the userData path, so
    flipping it moves settings and session state to a different directory and
    can make the app look like a fresh install.

    The replacement is length-preserving on purpose. Changing the ASAR length by
    even one byte would move every following header offset, and this script
    does not rewrite the header:

        const UPDATER_ENABLED = app.isPackaged && CHANNEL !== "dev";   60 bytes
        const UPDATER_ENABLED = false;<30 spaces>                       60 bytes

    The anchor is located by byte search inside the single ASAR entry
    /out/main/index.js, never by a hardcoded offset, because the offset moves
    with every release. On v1.18.33 it sits at entry offset 5116, absolute
    offset 101613023, line 120; on v1.18.34 the same line is two bytes later.
    A count other than exactly 1 aborts the run.

    This script is independent of patch-opencode-layout.ps1. They touch
    different files, use different backups and can be applied in any order.

.PARAMETER Path
    Path to app.asar. Leave empty to auto-detect the install location.

.PARAMETER Restore
    Copy this script's backup back over app.asar.

.PARAMETER DryRun
    Report what would change, write nothing.

.PARAMETER ClearUpdaterCache
    Delete the electron-updater cache directory, which holds any installer
    already downloaded before the patch. Combine with --dry-run to preview.

.PARAMETER SkipProcessCheck
    Do not refuse to run while the desktop app is open.

.PARAMETER SelfTest
    Build a throwaway ASAR fixture under %TEMP%, exercise the patch and its
    refusal paths against it, then delete it. Touches no real file.

.EXAMPLE
    .\patch-opencode-updater.ps1 -DryRun

.EXAMPLE
    .\patch-opencode-updater.ps1

.EXAMPLE
    .\patch-opencode-updater.ps1 -Restore

.EXAMPLE
    .\patch-opencode-updater.ps1 -SelfTest
#>

param()

$script:ValueOptions = @('path')

function Resolve-ScriptArgs {
    param([string[]] $Raw)

    $opts = @{}
    $problems = New-Object 'System.Collections.Generic.List[string]'

    for ($i = 0; $i -lt $Raw.Count; $i++) {
        $arg = $Raw[$i]
        if ([string]::IsNullOrEmpty($arg)) { continue }

        if ($arg -eq 'help') {
            $opts['help'] = $true
            continue
        }
        if (-not ($arg.StartsWith('-') -or $arg.StartsWith('/'))) {
            $problems.Add('unexpected value: ' + $arg)
            continue
        }

        # --name=value and -name=value are both accepted.
        $name = $arg
        $inline = $null
        $eq = $arg.IndexOf('=')
        if ($eq -gt 0) {
            $name = $arg.Substring(0, $eq)
            $inline = $arg.Substring($eq + 1)
        }
        $key = $name.TrimStart('-', '/').ToLowerInvariant()

        if ($script:ValueOptions -contains $key) {
            if ($null -eq $inline) {
                if ($i + 1 -ge $Raw.Count) {
                    $problems.Add('option ' + $name + ' needs a value')
                    continue
                }
                $i = $i + 1
                $inline = $Raw[$i]
            }
            $opts[$key] = $inline
            continue
        }

        # if/elseif rather than switch: continue and break inside a switch that
        # sits in a loop are easy to get wrong in PowerShell.
        if ($key -eq 'h' -or $key -eq 'help' -or $key -eq 'showhelp' -or $key -eq '?') {
            $opts['help'] = $true
        } elseif ($key -eq 'dryrun' -or $key -eq 'dry-run' -or $key -eq 'n' -or $key -eq 'whatif') {
            $opts['dryrun'] = $true
        } elseif ($key -eq 'restore') {
            $opts['restore'] = $true
        } elseif ($key -eq 'clearupdatercache' -or $key -eq 'clear-updater-cache') {
            $opts['clearupdatercache'] = $true
        } elseif ($key -eq 'forcenewbackup' -or $key -eq 'force-new-backup') {
            $opts['forcenewbackup'] = $true
        } elseif ($key -eq 'skipprocesscheck' -or $key -eq 'skip-process-check') {
            $opts['skipprocesscheck'] = $true
        } elseif ($key -eq 'selftest' -or $key -eq 'self-test') {
            $opts['selftest'] = $true
        } else {
            $problems.Add('unknown option: ' + $name + '   (try --help)')
        }
    }

    return [pscustomobject]@{ Options = $opts; Problems = @($problems.ToArray()) }
}

function Test-Flag {
    param($Options, [string] $Name)
    return $Options.ContainsKey($Name) -and $Options[$Name] -eq $true
}

function Get-OptionValue {
    param($Options, [string] $Name, [string] $Fallback)
    if ($Options.ContainsKey($Name)) { return [string] $Options[$Name] }
    return $Fallback
}

$ErrorActionPreference = 'Stop'

# ISO-8859-1 is a lossless byte<->codepoint mapping, so string offsets in the
# decoded text are exactly byte offsets in the file. Using the default UTF-8
# decoder would shift every offset past the first non-ASCII byte.
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:Utf8 = [System.Text.Encoding]::UTF8
$script:Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

# The one anchor this script knows how to disable. 60 bytes.
$script:Anchor = 'const UPDATER_ENABLED = app.isPackaged && CHANNEL !== "dev";'
# What it becomes: 30 bytes of real text, then 30 spaces of padding.
$script:Replace = 'const UPDATER_ENABLED = false;'
$script:Mark = 'const UPDATER_ENABLED = false;'

function Write-Title {
    param([string] $Text)
    Write-Host ''
    Write-Host ('== ' + $Text.ToUpperInvariant() + ' ==')
}

function Write-Ok {
    param([string] $Text)
    Write-Host ('  [ok]    ' + $Text)
}

function Write-Bad {
    param([string] $Text)
    Write-Host ('  [FAIL]  ' + $Text)
}

function Write-Note {
    param([string] $Text)
    Write-Host ('  [note]  ' + $Text)
}

function Show-Help {
    $help = @'
=====================================================================
 OpenCode desktop - disable the auto-updater
=====================================================================

 WHY
   There is no supported way to turn the desktop updater off. No setting,
   no environment variable, no config key. The feature is gated by one
   build-time constant in the Electron main bundle:

     const UPDATER_ENABLED = app.isPackaged && CHANNEL !== "dev";

   Setting that to false short-circuits the updater controller, so
   autoUpdater.checkForUpdates() is never called. Zero network requests,
   no release poll, no installer download, and the "Check for updates"
   button in Settings renders disabled.

   opencode.json autoupdate:false and OPENCODE_DISABLE_AUTOUPDATE are
   CLI/TUI only. The desktop app never reads opencode config for this.

 WHAT CHANGES
     const UPDATER_ENABLED = app.isPackaged && CHANNEL !== "dev";  60B
     const UPDATER_ENABLED = false;<30 spaces>                      60B

   Equal byte length is mandatory: a single byte of drift would move every
   following ASAR offset, and this script does not rewrite the header.

   The anchor is found by byte search inside the single ASAR entry
   /out/main/index.js, never by a hardcoded offset, because the offset
   moves with every release. If it is not found exactly once the run
   aborts without writing.

   Do not patch "prod" to "dev" instead. CHANNEL also picks APP_IDS,
   app.setName, the user model id and the userData path, so settings and
   session state would move to a different directory.

 OPTIONS
   -h, --help, -?, /?       This text.
   --dry-run, -n            Report what would change, write nothing.
   --restore                Copy a backup of this build back over app.asar.
   --clear-updater-cache    Delete the electron-updater cache directory
                            (any installer downloaded before the patch).
   --force-new-backup       Always write app.asar.updaterpatch.bak instead
                            of reusing an existing backup.
   --skip-process-check     Write even if the app is running. Not advised.
   --self-test              Exercise the patch on a temporary fixture.
   --path <value>           app.asar location. Auto-detected when omitted.

   PowerShell spellings work too: -DryRun, -Path, -Restore,
   -ClearUpdaterCache, -ForceNewBackup, -SkipProcessCheck, -SelfTest.
   Both -flag and --flag=value are accepted.

 BACKUPS
   This folder already holds app.asar.bak from the original script and
   app.asar.layoutpatch.bak from the layout patch script, so no new copy is
   made. The first of those three files whose size AND /package.json version
   both match the installed app.asar, and which still carries an unpatched
   updater anchor, is reused as the rollback source. A .bak left over from an
   older release has a different size and is skipped with a reason.

   -Restore searches the same three names and refuses if none matches, rather
   than downgrading the install. Restoring app.asar.layoutpatch.bak or
   app.asar.bak also reverts the layout pin, and the script says so.

 EXIT CODES
   0  success
   2  bad option, or app.asar not found
   3  restore requested but no usable backup
   4  refused: unexpected anchor count, so this is a different build
   5  write or backup failure
   6  verification failed, rolled back from backup
   7  the app is running from the install directory
   8  self-test failed

 EXAMPLES
   .\patch-opencode-updater.ps1 --dry-run
   .\patch-opencode-updater.ps1
   .\patch-opencode-updater.ps1 --clear-updater-cache
   .\patch-opencode-updater.ps1 --restore
   .\patch-opencode-updater.ps1 --force-new-backup --dry-run
   .\patch-opencode-updater.ps1 --self-test
   .\patch-opencode-updater.ps1 --path 'C:\somewhere\app.asar' --dry-run

 NOTES
   Quit OpenCode completely first: every window plus the tray icon.
   Electron keeps the old code in memory until every process is gone.

   Any desktop update replaces app.asar wholesale, so this patch has to
   be reapplied after each upgrade. Re-run with --dry-run to check.

   Restore is exact and only uses app.asar.updaterpatch.bak. The
   app.asar.bak and app.asar.layoutpatch.bak files belong to other
   scripts and are ignored.

   Read-only apart from the single app.asar, its own backup, and the
   updater cache directory when --clear-updater-cache is given.
'@
    Write-Host $help
}

# The install path is often pasted by hand and a backslash before "@" gets lost
# ("Programs\@opencode-aidesktop" -> "Programs@opencode-aidesktop"). The
# lookahead consumes nothing, so the "@" survives; matching "@" itself would
# delete the character.
function Repair-DroppedSeparator {
    param([string] $InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $InputPath }
    return [regex]::Replace($InputPath, '(?<=[^\\/])(?=@)', '\')
}

function Get-CandidatePaths {
    $list = New-Object 'System.Collections.Generic.List[string]'
    $localAppData = $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $list.Add((Join-Path $localAppData 'Programs\@opencode-aidesktop\resources\app.asar'))
        $list.Add((Join-Path $localAppData 'Programs\ai.opencode.desktop\resources\app.asar'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $list.Add((Join-Path $env:APPDATA '..\Local\Programs\@opencode-aidesktop\resources\app.asar'))
        $list.Add((Join-Path $env:APPDATA '..\Local\Programs\ai.opencode.desktop\resources\app.asar'))
    }
    return @($list.ToArray())
}

function Resolve-Target {
    param([string] $Supplied)
    $tried = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($Supplied)) {
        $tried.Add($Supplied)
        $repaired = Repair-DroppedSeparator $Supplied
        if ($repaired -ne $Supplied) { $tried.Add($repaired) }
    }
    foreach ($c in (Get-CandidatePaths)) { $tried.Add($c) }

    foreach ($t in $tried) {
        if (Test-Path -LiteralPath $t -PathType Leaf) {
            return [pscustomobject]@{
                Path  = (Resolve-Path -LiteralPath $t).Path
                Tried = @($tried.ToArray())
            }
        }
    }
    return [pscustomobject]@{ Path = $null; Tried = @($tried.ToArray()) }
}

# Any exe under the install folder, whatever its name. Reading .Path throws for
# processes owned by other users, hence the try/catch.
function Get-ProcessesUnder {
    param([string] $Directory)
    $found = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $procPath = $null
        try { $procPath = $p.Path } catch { $procPath = $null }
        if ([string]::IsNullOrWhiteSpace($procPath)) { continue }
        if ($procPath.StartsWith($Directory, [System.StringComparison]::OrdinalIgnoreCase)) {
            $found.Add([pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName })
        }
    }
    return @($found.ToArray())
}

function Find-AsarNode {
    param($Node, [string] $Prefix, [string] $Want)
    foreach ($prop in $Node.PSObject.Properties) {
        $childPath = $Prefix + '/' + $prop.Name
        if ($childPath -eq $Want) { return $prop.Value }
        $filesProp = $prop.Value.PSObject.Properties['files']
        if ($null -ne $filesProp) {
            $hit = Find-AsarNode -Node $filesProp.Value -Prefix $childPath -Want $Want
            if ($null -ne $hit) { return $hit }
        }
    }
    return $null
}

# Locates one packed entry and returns where its bytes live in the image.
# Data starts at 8 + headerSize, not 16 + jsonSize, so both fields matter.
function Get-AsarEntrySpan {
    param([byte[]] $Bytes, [string] $EntryPath)
    if ($null -eq $Bytes -or $Bytes.Length -lt 16) { return $null }
    $headerSize = [System.BitConverter]::ToUInt32($Bytes, 4)
    $jsonSize = [System.BitConverter]::ToUInt32($Bytes, 12)
    # headerSize counts the 16 byte prefix plus the JSON, so the payload begins
    # at 8 + headerSize, which equals 16 + jsonSize for every build seen so far.
    # The two are not added together: that would double count the JSON.
    if ((16 + [int64] $jsonSize) -gt $Bytes.Length) { return $null }
    if ((8 + [int64] $headerSize) -gt $Bytes.Length) { return $null }

    $headerJson = $script:Utf8.GetString($Bytes, 16, $jsonSize)
    $header = $headerJson | ConvertFrom-Json
    if ($null -eq $header.PSObject.Properties['files']) { return $null }

    $node = Find-AsarNode -Node $header.files -Prefix '' -Want $EntryPath
    if ($null -eq $node) { return $null }
    if ($null -ne $node.PSObject.Properties['unpacked']) { return $null }
    if ($null -eq $node.PSObject.Properties['offset']) { return $null }

    $size = [int] $node.size
    $start = 8 + [int] $headerSize + [int] ([int64] $node.offset)
    if ($size -le 0 -or ($start + $size) -gt $Bytes.Length) { return $null }
    return [pscustomobject]@{ Start = $start; Size = $size }
}

function Read-AsarEntryBytes {
    param([byte[]] $Bytes, $Span)
    if ($null -eq $Span) { throw 'Read-AsarEntryBytes called without a span' }
    if ($Span.Size -le 0) { throw ('Read-AsarEntryBytes got a bad size: ' + $Span.Size) }
    $slice = New-Object byte[] $Span.Size
    [Array]::Copy($Bytes, $Span.Start, $slice, 0, $Span.Size)
    # The leading comma is required: PowerShell enumerates a byte[] on output,
    # so a bare return would hand the caller 164444 boxed bytes instead.
    return ,$slice
}

function Read-AsarEntryText {
    param([byte[]] $Bytes, [string] $EntryPath)
    $span = Get-AsarEntrySpan -Bytes $Bytes -EntryPath $EntryPath
    if ($null -eq $span) { return $null }
    return $script:Latin1.GetString((Read-AsarEntryBytes -Bytes $Bytes -Span $span))
}

function Get-AsarVersion {
    param([byte[]] $Bytes)
    $pkg = Read-AsarEntryText -Bytes $Bytes -EntryPath '/package.json'
    if ([string]::IsNullOrEmpty($pkg)) { return 'unknown' }
    $m = [regex]::Match($pkg, '"version"\s*:\s*"([^"]+)"')
    if (-not $m.Success) { return 'unknown' }
    return $m.Groups[1].Value
}

# Byte search, ordinal, no text decoding involved. Scanning one 160 KB entry is
# fast; scanning the whole 146 MB image for every candidate is not.
function Find-ByteOccurrences {
    param([byte[]] $Haystack, [byte[]] $Needle)
    $hits = New-Object 'System.Collections.Generic.List[int]'
    if ($null -eq $Haystack -or $null -eq $Needle) { return @() }
    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return @() }
    $first = $Needle[0]
    $limit = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        if ($Haystack[$i] -ne $first) { continue }
        $ok = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { $hits.Add($i) }
    }
    return @($hits.ToArray())
}

# 1-based line number of a byte offset inside an entry.
function Get-LineColumn {
    param([byte[]] $EntryBytes, [int] $Offset)
    $line = 1
    $col = 1
    $stop = [Math]::Min($Offset, $EntryBytes.Length)
    for ($i = 0; $i -lt $stop; $i++) {
        if ($EntryBytes[$i] -eq 10) { $line++; $col = 1 } else { $col++ }
    }
    return [pscustomobject]@{ Line = $line; Column = $col }
}

# Decides write / skip / refuse. Shared by the real run and the self-test so
# both exercise identical logic.
function Get-PatchDecision {
    param([byte[]] $EntryBytes, [byte[]] $Anchor, [byte[]] $Replace, [byte[]] $Mark)

    $anchorHits = @(Find-ByteOccurrences -Haystack $EntryBytes -Needle $Anchor)
    $markHits = @(Find-ByteOccurrences -Haystack $EntryBytes -Needle $Mark)

    if ($Anchor.Length -ne $Replace.Length) {
        return [pscustomobject]@{
            Action = 'refuse'
            Offset = -1
            Reason = ('replacement is ' + $Replace.Length + ' bytes, anchor is ' + $Anchor.Length +
                      '; length-preserving is mandatory')
        }
    }
    if ($anchorHits.Count -eq 0 -and $markHits.Count -eq 1) {
        return [pscustomobject]@{ Action = 'skip'; Offset = $markHits[0]; Reason = $null }
    }
    if ($anchorHits.Count -eq 1 -and $markHits.Count -eq 0) {
        return [pscustomobject]@{ Action = 'write'; Offset = $anchorHits[0]; Reason = $null }
    }
    if ($anchorHits.Count -eq 0 -and $markHits.Count -eq 0) {
        return [pscustomobject]@{
            Action = 'refuse'
            Offset = -1
            Reason = 'anchor not found and no recognisable UPDATER_ENABLED marker present'
        }
    }
    return [pscustomobject]@{
        Action = 'refuse'
        Offset = -1
        Reason = ('anchor=' + $anchorHits.Count + ' marker=' + $markHits.Count + ', expected 1/0 or 0/1')
    }
}

function Invoke-LengthPreservingPatch {
    param([byte[]] $Image, [int] $Offset, [byte[]] $Replace)
    $out = New-Object byte[] $Image.Length
    [Array]::Copy($Image, 0, $out, 0, $Image.Length)
    [Array]::Copy($Replace, 0, $out, $Offset, $Replace.Length)
    # Comma operator, see Read-AsarEntryBytes.
    return ,$out
}

# Reports provider/owner/repo and the download cache location, so the
# alternative "make the check fail" route is documented without needing it.
function Get-UpdateConfigInfo {
    param([string] $ResourcesDir)
    $info = [pscustomobject]@{
        Path    = (Join-Path $ResourcesDir 'app-update.yml')
        Exists  = $false
        Owner   = $null
        Repo    = $null
        Provider = $null
        Channel = $null
        CacheName = $null
    }
    if (-not (Test-Path -LiteralPath $info.Path -PathType Leaf)) { return $info }
    $info.Exists = $true
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($info.Path) } catch { return $info }
    foreach ($field in @('owner', 'repo', 'provider', 'channel', 'updaterCacheDirName')) {
        $m = [regex]::Match($text, '(?m)^\s*' + $field + '\s*:\s*(.+?)\s*$')
        if (-not $m.Success) { continue }
        $v = $m.Groups[1].Value.Trim().Trim('"').Trim("'")
        switch ($field) {
            'owner' { $info.Owner = $v }
            'repo' { $info.Repo = $v }
            'provider' { $info.Provider = $v }
            'channel' { $info.Channel = $v }
            'updaterCacheDirName' { $info.CacheName = $v }
        }
    }
    return $info
}

# Reuse instead of piling up 146 MB copies. patch-opencode-layout.ps1 keeps its
# own backup in this same folder and the original script left app.asar.bak
# behind, so a third copy of the same build helps nobody.
#
# "Same build" is judged by package version plus exact byte size, which is
# deliberately strict: a .bak left over from an older release has a different
# size, and restoring that would silently downgrade the install. A backup is only
# accepted as a rollback source when it also still carries an unpatched updater
# anchor, otherwise this script could not undo its own change.
function Get-ExistingBackups {
    param([string] $ResourcesDir)
    $own = Join-Path $ResourcesDir 'app.asar.updaterpatch.bak'
    $all = @()
    if (Test-Path -LiteralPath $own -PathType Leaf) { $all += $own }
    $others = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in @(Get-ChildItem -LiteralPath $ResourcesDir -Filter 'app.asar*.bak' -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.FullName -ne $own) { $others.Add($f.FullName) }
    }
    return @($all + @($others.ToArray()))
}

function Get-BackupAdvisory {
    param([string] $Path)
    $name = Split-Path -Path $Path -Leaf
    if ($name -eq 'app.asar.layoutpatch.bak') {
        return 'made by patch-opencode-layout.ps1, so it predates the layout pin; restoring it reverts the layout pin too'
    }
    if ($name -eq 'app.asar.bak') {
        return 'left by the original script; it predates every later patch, so restoring it reverts those too'
    }
    return $null
}

function Select-BackupSource {
    param([byte[]] $Live, [string] $ResourcesDir)

    $result = [pscustomobject]@{
        Path = $null; Own = $false; Checked = @()
    }
    $liveVersion = Get-AsarVersion -Bytes $Live
    $own = Join-Path $ResourcesDir 'app.asar.updaterpatch.bak'

    foreach ($c in (Get-ExistingBackups -ResourcesDir $ResourcesDir)) {
        $info = [pscustomobject]@{
            Path = $c; Size = 0; Version = 'unknown'; Usable = $false; Why = ''
        }
        $ok = $false
        $why = $null
        try {
            $bytes = [System.IO.File]::ReadAllBytes($c)
            $info.Size = $bytes.Length
            $info.Version = Get-AsarVersion -Bytes $bytes
            if ($bytes.Length -ne $Live.Length) {
                $why = ('size ' + $bytes.Length + ' bytes, current install is ' + $Live.Length +
                        '; most likely a different release')
            } elseif ($info.Version -ne $liveVersion) {
                $why = ('version ' + $info.Version + ', current install is ' + $liveVersion)
            } else {
                $span = Get-AsarEntrySpan -Bytes $bytes -EntryPath '/out/main/index.js'
                if ($null -eq $span) {
                    $why = 'not a readable ASAR'
                } else {
                    $entry = Read-AsarEntryBytes -Bytes $bytes -Span $span
                    $anchorHits = @(Find-ByteOccurrences -Haystack $entry -Needle $script:Latin1.GetBytes($script:Anchor))
                    if ($anchorHits.Count -ne 1) {
                        $why = ('carries ' + $anchorHits.Count + ' unpatched updater anchors, expected 1;' +
                                ' cannot serve as a rollback source for this patch')
                    } else {
                        $ok = $true
                    }
                }
            }
        } catch {
            $why = 'unreadable: ' + $_.Exception.Message
        }
        $info.Usable = $ok
        if (-not $ok) { $info.Why = $why }
        $result.Checked += $info
        if ($ok) {
            $result.Path = $c
            $result.Own = ($c -eq $own)
            return $result
        }
    }
    return $result
}

function New-AsarFixture {
    param([string] $EntryText)

    $payload = $script:Latin1.GetBytes($EntryText)
    # Same shape as a real header: one top level "files", then the entry path
    # out/main/index.js as nested "files" objects.
    $header = '{"files":{"out":{"files":{"main":{"files":{"index.js":{"offset":"0","size":' +
        $payload.Length + '}}}}}}}'
    $json = $script:Utf8NoBom.GetBytes($header)
    $jsonSize = $json.Length

    # Field 4 is 8 + jsonSize, so 8 + headerSize lands exactly on 16 + jsonSize,
    # which is where the payload begins. Mirrors the real header layout.
    $head = New-Object byte[] 16
    [Array]::Copy([System.BitConverter]::GetBytes([uint32] 4), 0, $head, 0, 4)
    [Array]::Copy([System.BitConverter]::GetBytes([uint32] (8 + $jsonSize)), 0, $head, 4, 4)
    [Array]::Copy([System.BitConverter]::GetBytes([uint32] (4 + $jsonSize)), 0, $head, 8, 4)
    [Array]::Copy([System.BitConverter]::GetBytes([uint32] $jsonSize), 0, $head, 12, 4)

    $image = New-Object byte[] (16 + $jsonSize + $payload.Length)
    [Array]::Copy($head, 0, $image, 0, 16)
    [Array]::Copy($json, 0, $image, 16, $jsonSize)
    [Array]::Copy($payload, 0, $image, 16 + $jsonSize, $payload.Length)
    # Comma operator, see Read-AsarEntryBytes.
    return ,$image
}

function Invoke-SelfTest {
    Write-Title 'self test'
    # TEMP is always set on Windows; the fallback keeps the self-test runnable
    # under PowerShell on Linux, where it is not.
    $tempRoot = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $fixtureDir = Join-Path $tempRoot ('opencode-updater-selftest-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    $failures = New-Object 'System.Collections.Generic.List[string]'

    function Assert-That {
        param([bool] $Condition, [string] $Label)
        if ($Condition) {
            Write-Ok $Label
        } else {
            Write-Bad $Label
            $failures.Add($Label)
        }
    }

    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    try {
        $anchorB = $script:Latin1.GetBytes($script:Anchor)
        $replaceB = $script:Latin1.GetBytes($script:Replace + (' ' * ($script:Anchor.Length - $script:Replace.Length)))
        $markB = $script:Latin1.GetBytes($script:Mark)

        Assert-That ($anchorB.Length -eq 60) ('anchor is 60 bytes (got ' + $anchorB.Length + ')')
        Assert-That ($replaceB.Length -eq $anchorB.Length) 'replacement is length preserving'

        # 1. happy path
        $src = 'const a = 1;' + "`n" + $script:Anchor + "`n" + 'const b = 2;' + "`n"
        $image = New-AsarFixture -EntryText $src
        $span = Get-AsarEntrySpan -Bytes $image -EntryPath '/out/main/index.js'
        Assert-That ($null -ne $span) 'fixture header parses and locates /out/main/index.js'

        $entry = Read-AsarEntryBytes -Bytes $image -Span $span
        Assert-That ($script:Latin1.GetString($entry) -eq $src) 'fixture entry round-trips byte for byte'

        $d = Get-PatchDecision -EntryBytes $entry -Anchor $anchorB -Replace $replaceB -Mark $markB
        Assert-That ($d.Action -eq 'write') 'unpatched fixture decides write'
        $patched = Invoke-LengthPreservingPatch -Image $image -Offset $span.Start + $d.Offset -Replace $replaceB
        Assert-That ($patched.Length -eq $image.Length) 'patched image keeps the original total length'
        Assert-That (@(Find-ByteOccurrences -Haystack $patched -Needle $anchorB).Count -eq 0) 'anchor is gone after patching'
        Assert-That (@(Find-ByteOccurrences -Haystack $patched -Needle $markB).Count -eq 1) 'marker is present after patching'

        $span2 = Get-AsarEntrySpan -Bytes $patched -EntryPath '/out/main/index.js'
        Assert-That ($span2.Start -eq $span.Start -and $span2.Size -eq $span.Size) 'entry offsets unchanged, header intact'

        $entry2 = Read-AsarEntryBytes -Bytes $patched -Span $span2
        $d2 = Get-PatchDecision -EntryBytes $entry2 -Anchor $anchorB -Replace $replaceB -Mark $markB
        Assert-That ($d2.Action -eq 'skip') 'patched fixture decides skip on a second run'

        # 2. refuse when the anchor appears twice
        $dup = New-AsarFixture -EntryText ($script:Anchor + "`n" + $script:Anchor)
        $dupSpan = Get-AsarEntrySpan -Bytes $dup -EntryPath '/out/main/index.js'
        $dupEntry = Read-AsarEntryBytes -Bytes $dup -Span $dupSpan
        $d3 = Get-PatchDecision -EntryBytes $dupEntry -Anchor $anchorB -Replace $replaceB -Mark $markB
        Assert-That ($d3.Action -eq 'refuse') 'duplicate anchor refuses to write'

        # 3. refuse when neither anchor nor marker is present
        $other = New-AsarFixture -EntryText 'const somethingElse = true;' + "`n"
        $otherSpan = Get-AsarEntrySpan -Bytes $other -EntryPath '/out/main/index.js'
        $otherEntry = Read-AsarEntryBytes -Bytes $other -Span $otherSpan
        $d4 = Get-PatchDecision -EntryBytes $otherEntry -Anchor $anchorB -Replace $replaceB -Mark $markB
        Assert-That ($d4.Action -eq 'refuse') 'unknown build refuses to write'

        # 4. refuse when the replacement would change the length
        $wrongLengthB = $script:Latin1.GetBytes('const UPDATER_ENABLED = false;   ')
        $d5 = Get-PatchDecision -EntryBytes $entry -Anchor $anchorB -Replace $wrongLengthB -Mark $markB
        Assert-That ($d5.Action -eq 'refuse') 'length-changing replacement refuses to write'

        # 5. line/column reporting
        $lc = Get-LineColumn -EntryBytes $entry -Offset $d.Offset
        Assert-That ($lc.Line -eq 2 -and $lc.Column -eq 1) ('line/column of anchor is 2:1 (got ' + $lc.Line + ':' + $lc.Column + ')')

        # 6. on-disk round trip through the real write path
        $fixtureFile = Join-Path $fixtureDir 'app.asar'
        [System.IO.File]::WriteAllBytes($fixtureFile, $patched)
        $reloaded = [System.IO.File]::ReadAllBytes($fixtureFile)
        Assert-That ($reloaded.Length -eq $image.Length) 'reloaded file keeps the original total length'
        Assert-That (@(Find-ByteOccurrences -Haystack $reloaded -Needle $markB).Count -eq 1) 'reloaded file still carries the marker'
    } finally {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    if ($failures.Count -gt 0) {
        Write-Bad ('{0} self-test assertion(s) failed' -f $failures.Count)
        exit 8
    }
    Write-Ok 'all self-test assertions passed'
    Write-Note 'the real app.asar was not touched'
    exit 0
}

# ---------------------------------------------------------------- main

$parsed = Resolve-ScriptArgs -Raw $args
if ($parsed.Problems.Count -gt 0) {
    foreach ($problem in $parsed.Problems) { Write-Bad $problem }
    Write-Note 'Run with --help for the full option list.'
    exit 2
}

$Options = $parsed.Options
if (Test-Flag $Options 'help') { Show-Help; exit 0 }
if (Test-Flag $Options 'selftest') { Invoke-SelfTest }

$Path = Get-OptionValue $Options 'path' ''
$Restore = Test-Flag $Options 'restore'
$DryRun = Test-Flag $Options 'dryrun'
$ClearCache = Test-Flag $Options 'clearupdatercache'
$ForceNewBackup = Test-Flag $Options 'forcenewbackup'
$SkipProcessCheck = Test-Flag $Options 'skipprocesscheck'

Write-Title 'patch opencode desktop updater'

$resolved = Resolve-Target -Supplied $Path
if ($null -eq $resolved.Path) {
    Write-Bad 'Could not find app.asar. Pass --path explicitly.'
    foreach ($t in $resolved.Tried) { Write-Note ('tried: ' + $t) }
    exit 2
}

$target = $resolved.Path
$resourcesDir = Split-Path -Path $target -Parent
$installDir = Split-Path -Path $resourcesDir -Parent
$backupPath = Join-Path $resourcesDir 'app.asar.updaterpatch.bak'

Write-Ok ('target       : ' + $target)
Write-Ok ('install dir  : ' + $installDir)
Write-Ok ('backup       : ' + $backupPath)
if (-not [string]::IsNullOrWhiteSpace($Path) -and $resolved.Path -ne $Path) {
    Write-Note ('you typed    : ' + $Path)
    Write-Note ('repaired to  : ' + $resolved.Path)
}

$live = [System.IO.File]::ReadAllBytes($target)
Write-Ok ('size on disk : ' + $live.Length + ' bytes')
Write-Ok ('app version  : ' + (Get-AsarVersion -Bytes $live))

$cfg = Get-UpdateConfigInfo -ResourcesDir $resourcesDir
Write-Host ''
Write-Host '== update source =='
if ($cfg.Exists) {
    Write-Ok ('config       : ' + $cfg.Path)
    if ($cfg.Provider) { Write-Ok ('provider     : ' + $cfg.Provider) }
    if ($cfg.Owner -and $cfg.Repo) { Write-Ok ('release repo : ' + $cfg.Owner + '/' + $cfg.Repo) }
    if ($cfg.Channel) { Write-Ok ('channel      : ' + $cfg.Channel) }
} else {
    Write-Note ('no app-update.yml at ' + $cfg.Path)
    Write-Note 'electron-updater will fail its config load; that alone disables checking but shows an error.'
}
if (-not [string]::IsNullOrWhiteSpace($cfg.CacheName) -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $cacheDir = Join-Path $env:LOCALAPPDATA $cfg.CacheName
    if (Test-Path -LiteralPath $cacheDir) {
        $cacheBytes = 0
        try {
            $cacheBytes = (Get-ChildItem -LiteralPath $cacheDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        } catch { $cacheBytes = 0 }
        if ($null -eq $cacheBytes) { $cacheBytes = 0 }
        Write-Note ('cache dir    : ' + $cacheDir + '  (' + $cacheBytes + ' bytes)')
        if ($cacheBytes -gt 0) {
            Write-Note 'Run with --clear-updater-cache to drop installers downloaded before the patch.'
        }
    }
}

# Refuse to write while the app is alive: Electron keeps the old code mapped in
# and a running instance can overwrite the file or hold it open.
if (-not $SkipProcessCheck) {
    $running = @(Get-ProcessesUnder -Directory $installDir)
    if ($running.Count -gt 0) {
        Write-Host ''
        Write-Bad ('{0} process(es) are running from {1}' -f $running.Count, $installDir)
        foreach ($rp in $running) { Write-Note ('pid ' + $rp.Id + '  ' + $rp.Name) }
        Write-Note 'Quit OpenCode completely: every window plus the tray icon. Then run this again.'
        Write-Note 'Pass --skip-process-check to write anyway (not recommended).'
        exit 7
    }
    Write-Host ''
    Write-Ok 'no running process found under the install directory'
}

if ($Restore) {
    Write-Title 'restore'

    Write-Title 'backup search'
    Write-Note 'Reusing an existing backup of the same build instead of demanding this script''s own.'
    $choice = Select-BackupSource -Live $live -ResourcesDir $resourcesDir
    foreach ($b in $choice.Checked) {
        if ($b.Usable) {
            Write-Ok ('  usable     : ' + $b.Path + '  (' + $b.Size + ' bytes, v' + $b.Version + ')')
        } else {
            Write-Note ('  skipped    : ' + $b.Path + '  -- ' + $b.Why)
        }
    }
    if ($null -eq $choice.Path) {
        Write-Bad 'No backup of this exact build is available. Nothing to restore.'
        Write-Note 'Accepted file names: app.asar.updaterpatch.bak, app.asar.layoutpatch.bak, app.asar.bak'
        Write-Note 'Any of them works as long as the size and version match the installed app.asar.'
        exit 3
    }

    $bak = [System.IO.File]::ReadAllBytes($choice.Path)
    $bakSpan = Get-AsarEntrySpan -Bytes $bak -EntryPath '/out/main/index.js'
    if ($null -eq $bakSpan) {
        Write-Bad 'Backup does not look like a readable ASAR. Refusing to restore.'
        exit 3
    }
    $bakEntry = Read-AsarEntryBytes -Bytes $bak -Span $bakSpan
    # Built into locals first: a method call is not safe to pass straight to a
    # parameter, PowerShell argument mode would stop at the variable.
    $anchorB = $script:Latin1.GetBytes($script:Anchor)
    $bakAnchor = @(Find-ByteOccurrences -Haystack $bakEntry -Needle $anchorB)
    if ($bakAnchor.Count -ne 1) {
        Write-Bad ('Backup does not look like an unpatched build (anchor count ' + $bakAnchor.Count + '). Refusing to restore.')
        Write-Note 'Restore it by hand if you are sure, but check the file first.'
        exit 3
    }
    $advisory = Get-BackupAdvisory -Path $choice.Path
    if ($null -ne $advisory) {
        Write-Note ('heads up: this is ' + $advisory)
    }

    if ($DryRun) {
        Write-Note ('dry run: would copy ' + $choice.Path + ' over ' + $target)
        exit 0
    }

    try {
        [System.IO.File]::WriteAllBytes($target, $bak)
    } catch {
        Write-Bad ('write failed: ' + $_.Exception.Message)
        exit 5
    }
    $after = [System.IO.File]::ReadAllBytes($target)
    if ($after.Length -ne $bak.Length) {
        Write-Bad 'post-write length mismatch.'
        exit 6
    }
    Write-Ok ('restored ' + $live.Length + ' -> ' + $after.Length + ' bytes')
    Write-Note 'Automatic updates work again on the next launch.'
    exit 0
}

$span = Get-AsarEntrySpan -Bytes $live -EntryPath '/out/main/index.js'
if ($null -eq $span) {
    Write-Bad 'Could not locate /out/main/index.js in this ASAR. Refusing to touch it.'
    Write-Note 'The desktop build keeps the main bundle uncompressed, so this should not happen.'
    exit 4
}
$entryBytes = Read-AsarEntryBytes -Bytes $live -Span $span

$anchorB = $script:Latin1.GetBytes($script:Anchor)
$markB = $script:Latin1.GetBytes($script:Mark)
$replaceB = $script:Latin1.GetBytes($script:Replace + (' ' * ($script:Anchor.Length - $script:Replace.Length)))

Write-Host ''
Write-Host '== plan =='
$dataStart = 8 + [int] ([System.BitConverter]::ToUInt32($live, 4))
Write-Ok ('entry        : /out/main/index.js  asar offset ' + ($span.Start - $dataStart) + ', ' + $span.Size + ' bytes')
Write-Ok ('anchor       : ' + $anchorB.Length + ' bytes  ->  ' + $replaceB.Length + ' bytes')

$decision = Get-PatchDecision -EntryBytes $entryBytes -Anchor $anchorB -Replace $replaceB -Mark $markB

if ($decision.Action -eq 'refuse') {
    Write-Bad $decision.Reason
    Write-Note 'This build does not match the one this patch was written for. Not touching it.'
    Write-Note 'If the app auto-updated, the anchor moved. Re-check the new bundle before patching.'
    exit 4
}

$absOffset = $span.Start + $decision.Offset
$lc = Get-LineColumn -EntryBytes $entryBytes -Offset $decision.Offset

if ($decision.Action -eq 'skip') {
    Write-Title 'result'
    Write-Ok 'The updater is already disabled. Nothing to do.'
    Write-Ok ('marker at asar offset ' + $absOffset + ', entry offset ' + $decision.Offset + ', line ' + $lc.Line)
    Write-Note 'Automatic update checks are already short-circuited.'
    exit 0
}

Write-Ok ('anchor at asar offset ' + $absOffset + ', entry offset ' + $decision.Offset + ', line ' + $lc.Line + ', column ' + $lc.Column)
Write-Note ('sha256 before: ' + (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)

# Report the backup situation during a dry run too, so the plan is complete
# before anything is written.
Write-Title 'backup'
$planChoice = Select-BackupSource -Live $live -ResourcesDir $resourcesDir
foreach ($b in $planChoice.Checked) {
    if ($b.Usable) {
        Write-Ok ('  reuse      : ' + $b.Path + '  (' + $b.Size + ' bytes, v' + $b.Version + ')')
    } else {
        Write-Note ('  skipped    : ' + $b.Path + '  -- ' + $b.Why)
    }
}
$willReuse = ($null -ne $planChoice.Path) -and (-not $ForceNewBackup)
if ($willReuse) {
    Write-Note 'No new backup will be created; the one above is the same build.'
} elseif ($null -ne $planChoice.Path) {
    Write-Note ('--force-new-backup is set, so the usable backup above will be ignored and ' + $backupPath + ' written.')
} else {
    Write-Note ('No reusable backup found, so a new one will be written to ' + $backupPath)
}

if ($DryRun) {
    Write-Host ''
    if ($willReuse) {
        Write-Note ('dry run: would reuse ' + $planChoice.Path + ' as the rollback source')
    } else {
        Write-Note ('dry run: would back up to ' + $backupPath)
    }
    Write-Note 'dry run: would write the patched image. Nothing has been changed.'
    exit 0
}

Write-Title 'apply'
$rollbackSource = $null
if ($willReuse) {
    $rollbackSource = $planChoice.Path
    Write-Ok ('reusing existing backup, no new copy written: ' + $rollbackSource)
    $planAdvisory = Get-BackupAdvisory -Path $rollbackSource
    if ($null -ne $planAdvisory) {
        Write-Note ('heads up: ' + $planAdvisory)
    }
} else {
    try {
        [System.IO.File]::WriteAllBytes($backupPath, $live)
        $rollbackSource = $backupPath
        Write-Ok ('backup written, ' + $live.Length + ' bytes')
    } catch {
        Write-Bad ('backup failed: ' + $_.Exception.Message)
        Write-Note 'Nothing has been changed.'
        exit 5
    }
}

$patched = Invoke-LengthPreservingPatch -Image $live -Offset $absOffset -Replace $replaceB
try {
    [System.IO.File]::WriteAllBytes($target, $patched)
} catch {
    Write-Bad ('write failed: ' + $_.Exception.Message)
    Write-Note 'app.asar may be locked. Quit OpenCode fully and retry.'
    exit 5
}

# Verify by reading the file back, not by trusting the in-memory copy.
$verify = [System.IO.File]::ReadAllBytes($target)
$problems = New-Object 'System.Collections.Generic.List[string]'

if ($verify.Length -ne $live.Length) {
    $problems.Add('total length changed: ' + $live.Length + ' -> ' + $verify.Length)
}
$vSpan = Get-AsarEntrySpan -Bytes $verify -EntryPath '/out/main/index.js'
if ($null -eq $vSpan) {
    $problems.Add('patched image no longer parses as an ASAR')
} else {
    if ($vSpan.Start -ne $span.Start -or $vSpan.Size -ne $span.Size) {
        $problems.Add('entry moved: ' + $span.Start + '/' + $span.Size + ' -> ' + $vSpan.Start + '/' + $vSpan.Size)
    }
    $vEntry = Read-AsarEntryBytes -Bytes $verify -Span $vSpan
    if (@(Find-ByteOccurrences -Haystack $vEntry -Needle $anchorB).Count -ne 0) {
        $problems.Add('anchor still present after patching')
    }
    if (@(Find-ByteOccurrences -Haystack $vEntry -Needle $markB).Count -ne 1) {
        $problems.Add('marker missing after patching')
    }
    $vLine = Get-LineColumn -EntryBytes $vEntry -Offset $decision.Offset
    $shown = $script:Latin1.GetString($vEntry, $decision.Offset, $replaceB.Length).TrimEnd()
    Write-Ok ('line ' + $vLine.Line + ' now reads: ' + $shown)
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Bad $p }
    Write-Note 'Rolling back from the backup.'
    try {
        [System.IO.File]::WriteAllBytes($target, $live)
        Write-Ok 'rolled back, app.asar is byte identical to how it started'
    } catch {
        Write-Bad ('rollback failed: ' + $_.Exception.Message)
        Write-Note ('restore by hand from ' + $rollbackSource)
    }
    exit 6
}

Write-Host ''
Write-Ok 'the updater is disabled'
Write-Note ('sha256 after : ' + (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)
Write-Note 'restart OpenCode. Checks at startup and every 10 minutes now return immediately.'
Write-Note 'Settings > General > Updates > Check for updates will render disabled.'

if ($ClearCache) {
    Write-Title 'updater cache'
    if ([string]::IsNullOrWhiteSpace($cfg.CacheName) -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Write-Note 'cache directory name unknown; skipped.'
    } else {
        $cacheDir = Join-Path $env:LOCALAPPDATA $cfg.CacheName
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            Write-Note ('nothing to remove at ' + $cacheDir)
        } else {
            try {
                Remove-Item -LiteralPath $cacheDir -Recurse -Force
                Write-Ok ('removed ' + $cacheDir)
            } catch {
                Write-Bad ('cache removal failed: ' + $_.Exception.Message)
            }
        }
    }
}

Write-Host ''
Write-Note 'Every desktop update replaces app.asar, so re-run --dry-run after upgrading.'
if ($null -ne $rollbackSource) {
    Write-Note ('undo with: .\patch-opencode-updater.ps1 -Restore  (rollback source: ' + $rollbackSource + ')')
} else {
    Write-Note ('undo with: .\patch-opencode-updater.ps1 -Restore  (backup: ' + $backupPath + ')')
}
exit 0