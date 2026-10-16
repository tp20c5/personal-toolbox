// Regression test for timestamp.ts — run with: bun test-timestamp.ts
// No opencode runtime needed; the plugin's type-only import is erased by Bun.
import plugin from "./timestamp.ts"

const hook = (await (plugin as any)({}))["experimental.text.complete"]

async function run(text: string): Promise<string> {
  const output = { text }
  await hook({}, output)
  return output.text
}

const TS = "【送达时间：\\d{4}-\\d{2}-\\d{2} 星期[日一二三四五六] \\d{2}:\\d{2}】"

const cases: Array<[string, string]> = [
  // clean text -> exactly one stamp appended
  ["你好", "append-once"],
  // already stamped -> replaced, not duplicated
  [`你好\n\n【送达时间：2026-10-15 星期四 10:00】`, "idempotent"],
  // future stamp -> replaced
  [`内容\n\n【送达时间：2026-10-17 星期六 05:34】`, "future-stamp"],
  // wrong weekday -> replaced
  [`内容\n\n【送达时间：2026-10-15 星期五 19:00】`, "wrong-weekday"],
  // empty / ellipsis / real stamps mixed -> only one remains
  [`内容\n\n【送达时间：】\n\n【送达时间：...】\n\n【送达时间：2026-10-16 星期五 10:01】`, "mixed-dirty"],
  // bolded template leftover -> replaced
  [`内容\n\n**【送达时间：今天 HH:mm，本轮会话耗时：X分Y秒】**`, "bold-template"],
  // repeated stamp block in the body -> all removed, one stamp left at the end
  [
    "摘要：\n【送达时间：2026-10-17 星期六 05:34】\n【送达时间：2026-10-17 星期六 05:35】\n【送达时间：2026-10-17 星期六 05:35】\n【送达时间：2026-10-17 星期六 05:36】\n【送达时间：】\n正文结束",
    "repeated-block",
  ],
  // stamp glued to the end of a prose line (no blank line) -> still stripped
  ["最后一句【送达时间：2026-10-17 星期六 05:34】", "inline-tail"],
  // part that consists only of a stamp -> becomes just the authoritative stamp
  ["【送达时间：2026-10-17 星期六 05:34】", "stamp-only-part"],
]

let fail = 0
for (const [input, name] of cases) {
  const out = await run(input)
  const stampCount = (out.match(/【送达时间：/g) || []).length
  const endsOk = new RegExp(`${TS}$`).test(out)
  const midLines = out
    .split("\n")
    .slice(0, -1)
    .filter((l) => l.includes("【送达时间："))
  const ok = stampCount === 1 && endsOk && midLines.length === 0
  if (!ok) fail++
  console.log(`${ok ? "PASS" : "FAIL"} ${name}  stamps=${stampCount} endsOk=${endsOk} midStamps=${midLines.length}`)
  if (!ok) console.log("  out:", JSON.stringify(out))
}

console.log(fail === 0 ? "ALL PASS" : `${fail} FAILED`)
process.exit(fail === 0 ? 0 : 1)
