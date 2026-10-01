<#
.SYNOPSIS
    Pins the OpenCode desktop renderer to the classic (old) interface layout.

.DESCRIPTION
    The desktop renderer decides which layout to draw in this memo:

        const newLayoutDesigns = createMemo(() => {
          if (layoutUpgrade()) return true;
          if (!ready() && !oldInterfaceRetired()) return legacyNewLayoutDesignsDefault;
          ...
          return resolveNewLayoutDesigns(oldInterfaceRetired(), store.general?.newLayoutDesigns, ...);
        });

    Three separate things can force the new layout, and patching only one of
    them is not enough:

      1. layoutUpgrade()
         A ONE-SHOT migration window, not a version check. It is true only on
         the first launch after the app was upgraded across
         newLayoutDesignsUpgradeCutoff ("1.17.19"), because the app sets
         launchState.migrationApplied right after that launch.

      2. oldInterfaceRetired()
         A date gate: Date.now() >= oldInterfaceSunset, where
         oldInterfaceSunset is new Date(2026, 8, 14). Once that instant passes,
         resolveNewLayoutDesigns returns true no matter what the stored
         preference says, and a startup effect also writes
         general.newLayoutDesigns = true into the settings store. The setting
         becomes poisoned and the old layout is unreachable.

      3. store.general.newLayoutDesigns
         The persisted preference itself, normally false.

    So this script applies exactly two byte patches, both of the same length as
    the text they replace so that no offset inside the ASAR moves:

      A) if (layoutUpgrade()) return true;
         -> return false;<20 spaces>            (33 bytes -> 33 bytes)
         Kills the one-shot migration permanently.

      B) new Date(2026, 8, 14)
         -> new Date(<Year>, 8, 14)             (21 bytes -> 21 bytes)
         Moves the retirement gate out of reach, so the result no longer
         depends on the machine clock.

    Patch B alone is not enough: layoutUpgrade() would still flip the layout on
    the first launch after an upgrade. Patch A alone is not enough either: the
    retirement gate walks straight past it. Both are required, and after both
    are applied the persisted preference is honoured again, which is why
    -ResetStore exists.

    Every replacement is length-preserving on purpose. A single byte-length
    change would require rewriting the ASAR header offsets for every following
    entry, which this script deliberately does not attempt.

.PARAMETER Path
    Path to app.asar. Leave empty to auto-detect the install location.

.PARAMETER Year
    Four digit year for the retirement gate. Must be 4 digits so the byte length
    is preserved. 2099 by default.

.PARAMETER Restore
    Copy the backup this script made back over app.asar.

.PARAMETER DryRun
    Report what would change, write nothing.

.PARAMETER ResetStore
    Also set general.newLayoutDesigns (and general.layoutTransitionEligible)
    back to false in the settings store. Needed once, because the retirement
    gate may already have poisoned the stored preference to true.

.PARAMETER SkipProcessCheck
    Do not refuse to run while the desktop app is open.

.EXAMPLE
    .\patch-opencode-layout.ps1 -DryRun

.EXAMPLE
    .\patch-opencode-layout.ps1 -ResetStore

.NOTES
    Read-only against everything except the single app.asar it is pointed at.
    Creates at most one backup file next to it, and only if it is missing.
#>
# Options are parsed by hand instead of through param(). PowerShell's binder
# spells its own flags -Path and -Verbose, and does not reliably accept the
# GNU spellings --help or -h that people actually type. Parsing $args keeps
# -h, --help, -?, /?, --dry-run and --path=<value> all working, and lets an
# unknown flag produce a useful message instead of a binder error.
param()

$script:ValueOptions = @('path', 'year')

function Resolve-ScriptArgs {
    param([string[]] $Raw)

    $opts = @{}
    $problems = New-Object 'System.Collections.Generic.List[string]'

    for ($i = 0; $i -lt $Raw.Count; $i++) {
        $arg = $Raw[$i]
        if ([string]::IsNullOrEmpty($arg)) { continue }

        # A leading / is accepted too, for the /? and /Path spellings.
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
        } elseif ($key -eq 'resetstore' -or $key -eq 'reset-store') {
            $opts['resetstore'] = $true
        } elseif ($key -eq 'skipprocesscheck' -or $key -eq 'skip-process-check') {
            $opts['skipprocesscheck'] = $true
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

# Bytes of padding used to keep patch A the same length as its anchor.
$script:Pad20 = ' ' * 20

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

# Counts non-overlapping occurrences of a literal string and reports the first
# offset. Ordinal comparison: the file is bytes, not text with culture rules.
function Get-NeedleInfo {
    param([string] $Text, [string] $Needle)
    if ([string]::IsNullOrEmpty($Needle)) {
        return [pscustomobject]@{ Count = 0; First = -1 }
    }
    $count = 0
    $first = -1
    $start = 0
    while ($true) {
        $i = $Text.IndexOf($Needle, $start, [System.StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        if ($first -lt 0) { $first = $i }
        $count++
        $start = $i + $Needle.Length
    }
    return [pscustomobject]@{ Count = $count; First = $first }
}

# The install path is often pasted by hand and a backslash before "@" gets lost
# ("Programs\@opencode-aidesktop" -> "Programs@opencode-aidesktop"). The
# lookahead consumes nothing, so the "@" survives; matching "@" itself would
# delete the character.
function Show-Help {
    $help = @'
=====================================================================
 OpenCode desktop - pin the UI to the classic (old) layout
=====================================================================

 WHY TWO PATCHES
   Three separate things can force the new layout, so neutralizing only
   one of them is not enough:

     1. layoutUpgrade()
        Not a version check. It is true only during the first launch
        after the app was upgraded across version 1.17.19, because the
        app sets launchState.migrationApplied right afterwards.

     2. oldInterfaceRetired()
        A date gate: Date.now() >= new Date(2026, 8, 14). Once that
        instant passes, resolveNewLayoutDesigns returns true regardless
        of the stored preference, and a startup effect also writes
        general.newLayoutDesigns = true into the settings store. The
        preference is then poisoned and the old layout is unreachable.

     3. store.general.newLayoutDesigns
        The persisted preference itself, normally false.

   So exactly two byte patches are applied, each the same length as the
   text it replaces, so that no offset inside the ASAR moves:

     A  if (layoutUpgrade()) return true;     33 bytes
        > return false;<20 spaces>            33 bytes
        Kills the one-shot migration permanently.

     B  new Date(2026, 8, 14)                21 bytes
        > new Date(2099, 8, 14)              21 bytes
        Moves the retirement gate out of reach, so the result no longer
        depends on the machine clock.

   After both, the stored preference is honoured again and the in-app
   toggle works. -ResetStore undoes that stored value once.

 OPTIONS
   -h, --help, -?, /?       This text.
   --dry-run, -n            Report what would change, write nothing.
   --restore                Copy this script backup back over app.asar.
   --reset-store            Set general.newLayoutDesigns and
                            general.layoutTransitionEligible to false.
   --skip-process-check     Write even if the app is running. Not advised.
   --path <value>           app.asar location. Auto-detected when omitted.
   --year <4 digits>        Year for the retirement gate. Default 2099.

   PowerShell spellings work too: -DryRun, -Path, -Year, -ResetStore,
   -Restore, -SkipProcessCheck. Both -flag and --flag=value are accepted.

 EXIT CODES
   0  success
   2  bad option, or app.asar not found
   3  restore requested but no usable backup
   4  refused: unexpected anchor count, so this is a different build
   5  write or backup failure
   6  verification failed, rolled back from backup
   7  the app is running from the install directory

 EXAMPLES
   .\patch-opencode-layout.ps1 --dry-run
   .\patch-opencode-layout.ps1 --reset-store
   .\patch-opencode-layout.ps1 --restore
   .\patch-opencode-layout.ps1 --path 'C:\somewhere\app.asar' --dry-run

 NOTES
   Equal byte length is mandatory. A single byte of drift would move every
   following ASAR offset, and this script does not rewrite the header.

   Quit OpenCode completely first: every window plus the tray icon.
   Electron keeps the old code in memory until every process is gone.

   Restore is exact and only uses app.asar.layoutpatch.bak. The older
   app.asar.bak belongs to a different script and may be a different
   version, so it is ignored.

   Read-only apart from the single app.asar, its own backup, and the
   settings file when --reset-store is given.
'@
    Write-Host $help
}

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

# Reads one packed entry out of an ASAR image, or $null when it is not packed.
function Read-AsarEntryText {
    param([byte[]] $Bytes, [string] $EntryPath)
    if ($null -eq $Bytes -or $Bytes.Length -lt 16) { return $null }
    $headerSize = [System.BitConverter]::ToUInt32($Bytes, 4)
    $jsonSize = [System.BitConverter]::ToUInt32($Bytes, 12)
    if ((16 + $jsonSize) -gt $Bytes.Length) { return $null }

    $headerJson = $script:Utf8.GetString($Bytes, 16, $jsonSize)
    $header = $headerJson | ConvertFrom-Json
    if ($null -eq $header.PSObject.Properties['files']) { return $null }

    $node = Find-AsarNode -Node $header.files -Prefix '' -Want $EntryPath
    if ($null -eq $node) { return $null }
    if ($null -ne $node.PSObject.Properties['unpacked']) { return $null }
    if ($null -eq $node.PSObject.Properties['offset']) { return $null }

    $size = [int] $node.size
    $offset = [int] ([int64] $node.offset)
    $start = 8 + [int] $headerSize + $offset
    if ($size -le 0 -or ($start + $size) -gt $Bytes.Length) { return $null }
    return $script:Latin1.GetString($Bytes, $start, $size)
}

function Get-AsarVersion {
    param([byte[]] $Bytes)
    $pkg = Read-AsarEntryText -Bytes $Bytes -EntryPath '/package.json'
    if ([string]::IsNullOrEmpty($pkg)) { return 'unknown' }
    $m = [regex]::Match($pkg, '"version"\s*:\s*"([^"]+)"')
    if (-not $m.Success) { return 'unknown' }
    return $m.Groups[1].Value
}

function Get-SettingsFile {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $roots.Add((Join-Path $env:APPDATA 'ai.opencode.desktop'))
        $roots.Add((Join-Path $env:APPDATA 'ai.opencode.desktop.beta'))
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrEmpty($raw) -and $raw.Contains('newLayoutDesigns')) {
                return [pscustomobject]@{ Root = $root; File = $f.FullName; Raw = $raw }
            }
        }
    }
    return $null
}

# Edits the boolean in place rather than round-tripping through ConvertTo-Json,
# which would reformat the file and can reorder keys for no reason.
function Set-JsonBoolean {
    param([string] $Raw, [string] $Name, [bool] $Value)
    $literal = 'false'
    if ($Value) { $literal = 'true' }
    $rx = [regex]::new('("' + [regex]::Escape($Name) + '"\s*:\s*)(true|false)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $m = $rx.Match($Raw)
    if (-not $m.Success) {
        return [pscustomobject]@{ Changed = $false; Raw = $Raw; Reason = 'key "' + $Name + '" not found' }
    }
    if ($m.Groups[2].Value -eq $literal) {
        return [pscustomobject]@{ Changed = $false; Raw = $Raw; Reason = 'already ' + $literal }
    }
    $updated = $rx.Replace($Raw, ('${1}' + $literal), 1)
    return [pscustomobject]@{ Changed = $true; Raw = $updated; Reason = '' }
}

$parsed = Resolve-ScriptArgs -Raw $args
if ($parsed.Options.ContainsKey('help')) {
    Show-Help
    exit 0
}
if ($parsed.Problems.Count -gt 0) {
    foreach ($problem in $parsed.Problems) { Write-Bad $problem }
    Write-Note 'Run with --help for the full option list.'
    exit 2
}

$Path = Get-OptionValue $parsed.Options 'path' ''
$Year = Get-OptionValue $parsed.Options 'year' '2099'
$Restore = Test-Flag $parsed.Options 'restore'
$DryRun = Test-Flag $parsed.Options 'dryrun'
$ResetStore = Test-Flag $parsed.Options 'resetstore'
$SkipProcessCheck = Test-Flag $parsed.Options 'skipprocesscheck'

Write-Title 'patch opencode desktop layout'

if (-not [regex]::IsMatch($Year, '^\d{4}$')) {
    Write-Bad ('-Year must be exactly four digits, got: ' + $Year)
    Write-Note 'Four digits is required so the replacement keeps the byte length of its anchor.'
    exit 2
}
$targetYear = [int] $Year
if ($targetYear -le (Get-Date).Year) {
    Write-Bad ('-Year ' + $Year + ' is not in the future, so the retirement gate stays open.')
    Write-Note 'Pick a year well ahead of today, for example 2099.'
    exit 2
}

$resolved = Resolve-Target -Supplied $Path
if ([string]::IsNullOrEmpty($resolved.Path)) {
    Write-Bad 'Could not find app.asar. Pass -Path explicitly.'
    foreach ($t in $resolved.Tried) { Write-Note ('tried: ' + $t) }
    exit 2
}
$target = $resolved.Path
$installDir = Split-Path -Parent (Split-Path -Parent $target)
$backupPath = Join-Path (Split-Path -Parent $target) 'app.asar.layoutpatch.bak'

Write-Ok('target       : ' + $target)
Write-Ok('install dir  : ' + $installDir)
Write-Ok('backup       : ' + $backupPath)
if (-not [string]::IsNullOrWhiteSpace($Path) -and $resolved.Path -ne $Path) {
    Write-Note('you typed    : ' + $Path)
    Write-Note('repaired to  : ' + $resolved.Path)
}
Write-Ok('gate year    : ' + $Year)

# Writing app.asar while the renderer has it mapped risks a partial write, and
# Electron keeps the old code in memory until every process is gone anyway.
if (-not $DryRun -and -not $SkipProcessCheck) {
    $running = @(Get-ProcessesUnder -Directory $installDir)
    if ($running.Count -gt 0) {
        Write-Bad ($running.Count + ' process(es) are running from ' + $installDir)
        foreach ($rp in $running) { Write-Note ('pid ' + $rp.Id +'  ' + $rp.Name) }
        Write-Note 'Quit OpenCode completely: every window plus the tray icon. Then run this again.'
        Write-Note 'Pass -SkipProcessCheck to write anyway (not recommended).'
        exit 7
    }
    Write-Ok 'no running process found under the install directory'
}

$live = [System.IO.File]::ReadAllBytes($target)
Write-Ok('size on disk : ' + $live.Length + ' bytes')
Write-Ok('app version  : ' + (Get-AsarVersion -Bytes $live))

if ($Restore) {
    Write-Title 'restore'
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Write-Bad ('No backup at ' + $backupPath)
        Write-Note 'Nothing to restore. The app.asar.bak from the old script is a different file and may belong to a different version.'
        exit 3
    }
    $bak = [System.IO.File]::ReadAllBytes($backupPath)
    if ((Get-NeedleInfo -Text ($script:Latin1.GetString($bak)) -Needle 'if (layoutUpgrade()) return true;').Count -ne 1) {
        Write-Bad 'Backup does not look like an unpatched build (layoutUpgrade anchor not unique). Refusing to restore.'
        Write-Note 'Restore it by hand if you are sure, but check the file first.'
        exit 3
    }
    if ($DryRun) {
        Write-Note('dry run: would copy ' + $backupPath + ' over ' + $target)
        exit 0
    }
    [System.IO.File]::WriteAllBytes($target, $bak)
    Write-Ok('restored ' + $live.Length + ' -> ' + $bak.Length + ' bytes')
    Write-Note 'The old layout should come back on the next launch.'
    exit 0
}

$patches = @(
    [pscustomobject]@{
        Id      = 'A: one-shot migration'
        Anchor  = 'if (layoutUpgrade()) return true;'
        Replace = 'return false;' + $script:Pad20
        Mark    = 'return false;' + $script:Pad20
    },
    [pscustomobject]@{
        Id      = 'B: retirement date gate'
        Anchor  = 'new Date(2026, 8, 14)'
        Replace = ('new Date(' + $Year + ', 8, 14)')
        Mark    = ('new Date(' + $Year + ', 8, 14)')
    }
)

Write-Title 'plan'
foreach ($p in $patches) {
    if ($p.Anchor.Length -ne $p.Replace.Length) {
        Write-Bad ($p.Id + ': replacement is ' + $p.Replace.Length + ' bytes, anchor is ' + $p.Anchor.Length)
        Write-Note 'Length-preserving is mandatory. Stop.'
        exit 4
    }
}
Write-Ok ('both replacements are length preserving (' +
    $patches[0].Replace.Length + ' and ' + $patches[1].Replace.Length + ' bytes)')

# Decide, per patch, whether to write, skip, or stop. Refusing on anything
# unexpected matters more than finishing: a wrong anchor count means the build
# is not the one this was designed for.
$text = $script:Latin1.GetString($live)
$plan = New-Object 'System.Collections.Generic.List[object]'
$blocking = $false

foreach ($p in $patches) {
    $anchorHits = Get-NeedleInfo -Text $text -Needle $p.Anchor
    $markHits = Get-NeedleInfo -Text $text -Needle $p.Mark

    if ($anchorHits.Count -eq 0 -and $markHits.Count -eq 1) {
        $plan.Add([pscustomobject]@{ Patch = $p; Action = 'skip'; Offset = $markHits.First })
    } elseif ($anchorHits.Count -eq 1 -and $markHits.Count -eq 0) {
        $plan.Add([pscustomobject]@{ Patch = $p; Action = 'write'; Offset = $anchorHits.First })
    } elseif ($anchorHits.Count -eq 0 -and $markHits.Count -eq 0) {
        # Neither present. For the date gate this usually means it already points
        # at some other year, so report that instead of a bare "not found".
        $m = [regex]::Match($text, 'new Date\((\d{4}), 8, 14\)')
        if ($m.Success) {
            Write-Bad ($p.Id + ': the gate is already set to year ' + $m.Groups[1].Value + ', not ' + $Year)
        } else {
            Write-Bad ($p.Id + ': anchor not found and no recognisable date gate present')
        }
        Write-Note 'This build does not match the one this patch was written for. Not touching it.'
        $blocking = $true
    } else {
        Write-Bad ($p.Id + ': anchor=' + $anchorHits.Count + ' marker=' + $markHits.Count + ', expected 1/0 or 0/1')
        $blocking = $true
    }
}

foreach ($item in $plan) {
    $verb = 'would patch'
    if ($item.Action -eq 'skip') { $verb = 'already patched' }
    Write-Host ('  ' + $item.Patch.Id.PadRight(30) + $verb.PadRight(16) + 'offset ' + $item.Offset)
}

if ($blocking) {
    Write-Bad 'Refusing to write. Nothing has been changed.'
    Write-Note 'Run with -DryRun to inspect, or check whether the app auto-updated after the patch was designed.'
    exit 4
}

$toWrite = @($plan | Where-Object { $_.Action -eq 'write' })
if ($toWrite.Count -eq 0) {
    Write-Title 'result'
    Write-Ok 'Both patches are already in place. Nothing to do.'
    Write-Note 'The retirement gate is disabled, so the stored preference is honoured again.'
} else {
    Write-Note ('backup    : ' + $backupPath)
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        if ($DryRun) {
            Write-Note ('dry run: would create backup from ' + $target)
        } else {
            [System.IO.File]::WriteAllBytes($backupPath, $live)
            Write-Ok ('created backup, ' + $live.Length + ' bytes')
        }
    } else {
        Write-Ok 'backup already exists, leaving it untouched'
        $existing = [System.IO.File]::ReadAllBytes($backupPath)
        $existingHits = Get-NeedleInfo -Text $script:Latin1.GetString($existing) -Needle 'if (layoutUpgrade()) return true;'
        if ($existingHits.Count -ne 1) {
            Write-Bad 'Existing backup does not look like an unpatched build (layoutUpgrade anchor not unique).'
            Write-Note 'Not overwriting it. Move it aside yourself if you want a fresh one.'
            exit 5
        }
        Write-Ok 'existing backup verified as unpatched'
    }

    if ($DryRun) {
        Write-Title 'dry run'
        Write-Ok 'No bytes were written.'
        Write-Note 'Drop -DryRun to apply for real.'
        exit 0
    }

    $working = $script:Latin1.GetString($live)
    foreach ($item in $toWrite) {
        $working = $working.Remove($item.Offset, $item.Patch.Anchor.Length).Insert($item.Offset, $item.Patch.Replace)
        Write-Ok ('patched ' + $item.Patch.Id + ' at offset ' + $item.Offset)
    }

    if ($working.Length -ne $live.Length) {
        Write-Bad ('internal error: length drifted ' + $live.Length + ' -> ' + $working.Length)
        exit 5
    }

    try {
        [System.IO.File]::WriteAllBytes($target, $script:Latin1.GetBytes($working))
    } catch {
        Write-Bad ('write failed: ' + $_.Exception.Message)
        Write-Note 'The file was left untouched or partially written; restoring from backup.'
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($backupPath))
            Write-Ok 'rolled back from backup'
        }
        exit 5
    }

    Write-Title 'verify'
    $after = [System.IO.File]::ReadAllBytes($target)
    if ($after.Length -ne $live.Length) {
        Write-Bad ('size changed after write: ' + $live.Length + ' -> ' + $after.Length)
    } else {
        Write-Ok ('size unchanged: ' + $after.Length + ' bytes')
    }
    $afterText = $script:Latin1.GetString($after)
    $bad = 0
    foreach ($p in $patches) {
        $anchorHits = Get-NeedleInfo -Text $afterText -Needle $p.Anchor
        $markHits = Get-NeedleInfo -Text $afterText -Needle $p.Mark
        $okState = ($anchorHits.Count -eq 0 -and $markHits.Count -eq 1)
        $detail = 'anchor=' + $anchorHits.Count + ' marker=' + $markHits.Count + ' (want 0/1)'
        if ($okState) { Write-Ok ($p.Id + ': ' + $detail) } else { Write-Bad ($p.Id + ': ' + $detail); $bad++ }
    }
    foreach ($guard in @('oldInterfaceRetired', 'newLayoutDesigns', 'createMemo')) {
        $beforeCount = (Get-NeedleInfo -Text $text -Needle $guard).Count
        $afterCount = (Get-NeedleInfo -Text $afterText -Needle $guard).Count
        if ($beforeCount -eq $afterCount) {
            Write-Ok ('guard "' + $guard + '" unchanged at ' + $afterCount)
        } else {
            Write-Bad ('guard "' + $guard + '" moved ' + $beforeCount + ' -> ' + $afterCount)
            $bad++
        }
    }
    if ($bad -gt 0) {
        Write-Bad 'Verification failed. Rolling back.'
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($backupPath))
        Write-Ok 'rolled back from backup'
        exit 6
    }
    Write-Ok 'all checks passed'
}

Write-Title 'settings store'
$store = Get-SettingsFile
if ($null -eq $store) {
    Write-Note 'No settings file with newLayoutDesigns was found. Nothing to reset.'
} else {
    Write-Ok ('file: ' + $store.File)
    $preview = [regex]::Match($store.Raw, '"newLayoutDesigns"\s*:\s*(true|false)')
    if ($preview.Success) {
        Write-Ok ('current general.newLayoutDesigns = ' + $preview.Groups[1].Value)
    }
    if ($preview.Success -and $preview.Groups[1].Value -eq 'true') {
        Write-Note 'This is the poisoned value written by the retirement gate.'
        Write-Note 'Run with -ResetStore to set it back to false, or edit it by hand.'
    }
    if ($ResetStore) {
        if ($DryRun) {
            Write-Note 'dry run: would set general.newLayoutDesigns and general.layoutTransitionEligible to false'
        } else {
            $raw = $store.Raw
            $raw2 = Set-JsonBoolean -Raw $raw -Name 'newLayoutDesigns' -Value $false
            $raw3 = Set-JsonBoolean -Raw $raw2.Raw -Name 'layoutTransitionEligible' -Value $false
            if ($raw2.Changed -or $raw3.Changed) {
                $storeBak = $store.File + '.layoutpatch.bak'
                if (-not (Test-Path -LiteralPath $storeBak -PathType Leaf)) {
                    [System.IO.File]::WriteAllText($storeBak, $store.Raw, $script:Utf8NoBom)
                    Write-Ok ('settings backup: ' + $storeBak)
                }
                [System.IO.File]::WriteAllText($store.File, $raw3.Raw, $script:Utf8NoBom)
                Write-Ok 'settings updated'
            } else {
                Write-Note ('settings left alone: ' + $raw2.Reason + '; ' + $raw3.Reason)
            }
        }
    }
}

Write-Title 'next'
Write-Note 'Quit the OpenCode desktop app completely before writing, then start it again.'
Write-Note 'If the layout is still the new one, close every window and the tray icon, then relaunch.'
Write-Note 'Undo at any time with -Restore.'
exit 0