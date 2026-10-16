# opencode-serve

An OpenCode plugin that stamps every assistant text reply with the real
delivery time, in the format:

```
【送达时间：2026-10-16 星期五 15:56】
```

| File | Role |
| --- | --- |
| `timestamp.ts` | The plugin itself |
| `test-timestamp.ts` | Regression test for the cleaning logic (run with Bun) |

> 中文摘要：一个 OpenCode 插件，在每条助手回复末尾追加真实送达时间戳。
> 关键设计是「先清洗、再盖戳」：模型自己模仿生成的脏时间戳（未来时间、
> 照抄上一条、加粗、空值、`HH:mm` 占位、整段复读）会在落库前被全部剥掉，
> 最后只追加一个由本机时钟决定的权威时间戳。无依赖、无网络请求。

## Why not just append a timestamp

The naive version of this plugin checks "does the reply already end with a
timestamp, then skip". That fails in practice, because the model *also* learns
the stamp format from context (its own past replies, memories, quoted files)
and starts writing stamps itself — with hallucinated future times, copies of
the previous reply's time, bolded templates, or empty placeholders. A
skip-if-present check lets every one of those through, and often stacks a
second stamp on top.

This plugin instead:

1. Deletes every body line that consists solely of a stamp (optionally wrapped
   in `**` / `__` / `` ` `` emphasis) — this is the model's repeated-stamp
   block.
2. Strips any trailing stamp of any shape, including glued to the last prose
   line.
3. Trims trailing blank lines.
4. Appends exactly one stamp taken from `new Date()`.

Clean-then-append is idempotent: run it any number of times, the reply ends up
with exactly one current stamp. Existing pollution in old replies self-heals
as the model re-emits those lines in new generations.

## Install

Copy `timestamp.ts` into the OpenCode plugin directory and restart OpenCode:

```bash
mkdir -p ~/.config/opencode/plugin
cp timestamp.ts ~/.config/opencode/plugin/
```

(Project-level alternative: `.opencode/plugin/timestamp.ts` in the repo you
work in.)

The `import type { Plugin } from "@opencode-ai/plugin"` line is types-only and
erased at runtime — no npm install is required for the plugin to load.

## Hook and timing semantics (v1)

The plugin uses the `experimental.text.complete` hook. In OpenCode v1 it fires
once per **text part** when that part's stream ends
(`session/processor.ts`, `text-end`), and the mutated text is persisted.

Consequences:

- A reply that interleaves several text parts with tool calls gets one stamp
  per part. That is the hook's granularity, not a bug.
- Timestamps have minute resolution, so two parts completing in the same
  minute show the same time.

## Test

```bash
bun test-timestamp.ts
```

Nine dirty-input cases (future stamps, wrong weekday, empty stamps, bolded
templates, repeated stamp blocks, inline tail stamps, stamp-only parts) must
all come out with exactly one valid current stamp.

## License

[MIT](../LICENSE)
