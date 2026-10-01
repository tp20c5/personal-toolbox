# opencode-desktop

Two patch scripts for the OpenCode desktop app on Windows
(`@opencode-ai/desktop`, installed as `@opencode-aidesktop`):

| Script | Goal |
| --- | --- |
| `patch-opencode-layout.ps1` | Pin the renderer to the **classic (old) interface layout** |
| `patch-opencode-updater.ps1` | Disable the **auto-updater** |
| `probe-opencode-layout.ps1` | Read-only probe: is a given build patchable at all? |

They are independent of each other. They touch different files, use different
backups, and can be applied in any order.

> 中文摘要：两个用于 Windows 版 OpenCode 桌面端的补丁脚本，另有只读探针。原理都是对
> `app.asar` 做等长字节替换，改完先备份、可一键回滚。纯 PowerShell 实现，无依赖。

## Requirements

- Windows
- PowerShell 5.1 or newer (what ships with Windows)
- No modules, no downloads, no admin rights required

Run them from a normal PowerShell window. If execution policy blocks the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\patch-opencode-layout.ps1 -DryRun
```

## Always start with a dry run

```powershell
# see what would change, write nothing
.\patch-opencode-layout.ps1 -DryRun
.\patch-opencode-updater.ps1 -DryRun
```

A dry run reports the byte offset, the surrounding source line and the SHA-256
before and after. Read it. If the printed source line is not the constant you
expected, stop.

## Quit the app first

Both scripts refuse to run while the desktop app is running, because the app
holds `app.asar` open and would overwrite the patch on exit. Quit it properly
(including the tray icon) before patching, then relaunch.

## Pinning the classic layout

```powershell
.\patch-opencode-layout.ps1            # patch
.\patch-opencode-layout.ps1 -ResetStore # also clear a preference already poisoned to true
.\patch-opencode-layout.ps1 -Restore   # undo
```

**What it does.** Three separate things can force the new layout, and patching
one is not enough:

1. **`layoutUpgrade()`** — a one-shot migration window. True only on the first
   launch after the app was upgraded across `newLayoutDesignsUpgradeCutoff`,
   because the app records `launchState.migrationApplied` right after that
   launch.
2. **`oldInterfaceRetired()`** — a date gate at `oldInterfaceSunset`, currently
   `new Date(2026, 8, 14)`. Once that instant passes, the stored preference is
   ignored and a startup effect writes `newLayoutDesigns = true` into the
   settings store. The preference becomes poisoned.
3. **`store.general.newLayoutDesigns`** — the persisted preference itself.

The script applies exactly two equal-length byte patches:

```
A)  if (layoutUpgrade()) return true;   ->  return false;<20 spaces>   (33 -> 33 bytes)
B)  new Date(2026, 8, 14)              ->  new Date(<Year>, 8, 14)     (21 -> 21 bytes)
```

Patch A kills the one-shot migration. Patch B moves the retirement gate out of
reach, so the result no longer depends on the machine clock. Both are required.
Use `-Year 2099` to pick a different gate year (must be four digits so the byte
length is preserved).

If you already ran the app past the sunset date, run once with `-ResetStore` to
set `general.newLayoutDesigns` and `general.layoutTransitionEligible` back to
`false` in the settings store.

## Disabling the auto-updater

```powershell
.\patch-opencode-updater.ps1               # patch
.\patch-opencode-updater.ps1 -DryRun       # preview
.\patch-opencode-updater.ps1 -Restore      # undo
.\patch-opencode-updater.ps1 -SelfTest     # verify the tool against a throwaway fixture
```

**What it does.** The feature hangs off one compile-time constant in the Electron
main bundle:

```js
const raw = "prod";
const CHANNEL = raw;
const UPDATER_ENABLED = app.isPackaged && CHANNEL !== "dev";   // 60 bytes
```

The controller's first statement is `if (!input.enabled) return ...`, so a false
value short-circuits every check. The patch replaces that line, length-preservingly:

```js
const UPDATER_ENABLED = false;<30 spaces>                       // 60 bytes
```

After it:

- the startup check and the 10-minute interval both become no-ops
- no release poll, no ~126 MB download, no pending installer
- Settings > General > Updates renders "Check for updates" as disabled

Note `autoDownload` and `autoInstallOnAppQuit` were *already* false upstream, but
the app's own controller calls `downloadUpdate()` the moment it sees a newer
release. Without this patch the download still happens silently and only the
final install waits for a click. This patch removes the download too.

Optionally clear any installer already downloaded before the patch:

```powershell
.\patch-opencode-updater.ps1 -ClearUpdaterCache
```

**Do not** patch `"prod"` to `"dev"` instead. `CHANNEL` is also used for
`APP_IDS`, `TAURI_APP_IDS`, `app.setName`, `app.setAppUserModelId` and the
`userData` path, so flipping it relocates your settings and sessions.

## The probe (read-only)

```powershell
.\probe-opencode-layout.ps1 -SelfTest              # prove the tool works first
.\probe-opencode-layout.ps1 -Path "$env:LOCALAPPDATA\Programs\@opencode-aidesktop"
```

It never writes to the target. It answers:

1. Is the bundle minified? (decides whether a literal patch is possible at all)
2. Which layout strings are still present, how many times, at which byte offsets?
   (a patch is only safe when the count is exactly 1)
3. Which file inside the ASAR contains each hit, at which line and column?

`-ExtractOwner <folder>` exports the files containing needle hits, so you can
hand a 140 MB ASAR problem to someone else as a few small files. `-SelfTest` is
the only mode that touches the filesystem, and it creates and deletes one scratch
file under `%TEMP%`.

## Why equal-length patches only

Changing the length of an ASAR entry by even one byte would move every following
header offset, and none of these scripts rewrite the header. Every replacement is
therefore byte-for-byte the same length as the text it replaces, with the slack
filled by spaces. That is also why `-Year` must be exactly four digits.

## Version caveats

**Every desktop update replaces `app.asar`, so all patches are lost on upgrade.**
Re-run `--dry-run` after updating.

No needle is located by a hardcoded offset — they are found by byte search inside
the named ASAR entry, because offsets move with every release. A match count other
than exactly 1 aborts the run.

Some builds may be minified, in which case local identifiers are renamed and the
literal needles do not exist. The probe reports this. If upstream ever deletes
the old UI code outright, no patch can bring it back.

## Safety properties

- Backup written next to the target before the first write, and never overwritten
- `-DryRun` writes nothing at all
- `-Restore` puts the backup back
- Only `app.asar` and (with `-ResetStore` / `-ClearUpdaterCache`) the settings
  file and the updater cache are ever written
- Console output is intentionally ASCII-only so it cannot turn into mojibake on
  a legacy Windows console

## License

[MIT](../LICENSE)