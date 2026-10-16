# personal-toolbox

Small, self-contained tools I keep reaching for. Mostly PowerShell and shell
scripts, no build step, no dependencies, no telemetry.

Mostly written with AI assistance (vibecoded) and tested on my own machine, so
expect the rough edges that comes with. Each tool lives in its own folder with
its own README. Everything here is MIT licensed.

> 本仓库收录自用的小工具脚本，方便共享和备份。大部分是纯 PowerShell / shell 实现，无依赖、无构建步骤。
> 每个工具独立目录、独立说明文档，主要靠vibecoding产出、本机测试。开源仓库仅作为个人备份与分享，请勿依赖其长期可用性。

---

## Tools

| Tool | What it does | Platform |
| --- | --- | --- |
| [opencode-desktop/](opencode-desktop/) | Keep the OpenCode desktop app on the classic layout, and switch its auto-updater off | Windows / PowerShell 5.1+ |
| [opencode-serve/](opencode-serve/) | OpenCode plugin: stamp every assistant reply with the real delivery time (clean-then-append) | Any / TypeScript |

---

## Why these exist

The OpenCode desktop app (Electron, `@opencode-ai/desktop`) ships two behaviours
that I wanted to change, and it exposes no setting, environment variable or
config key for either one. So both tools do what the app's own CLI does not: they
open `resources\app.asar` and rewrite one constant, length-preservingly, after
taking a backup.

Both are read-only against everything except the single `app.asar` they are
pointed at, and both refuse to guess: a needle that is not found exactly once
aborts the run instead of writing something ambiguous.

See [opencode-desktop/README.md](opencode-desktop/README.md) for the mechanism,
the version caveats and the undo path.

---

## License

[MIT](LICENSE)
