import type { Plugin } from "@opencode-ai/plugin"

function formatTime(date: Date): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')

  const weekdays = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六']
  const weekday = weekdays[date.getDay()]

  return `【送达时间：${year}-${month}-${day} ${weekday} ${hours}:${minutes}】`
}

// 任意形态的送达时间戳：标准格式、加粗、HH:mm 占位、空值、模板残骸等一律视为脏戳
// 匹配【送达时间：...】直至下一个】（内部不含】）；两侧允许 ** / __ / ` 等强调包裹
const STAMP_ANY = '【送达时间：[^】]*】'
const WRAP = '(?:\\*{1,3}|_{1,3}|`)?'

export default (async ({ client, project, directory, $ }) => {
  return {
    "experimental.text.complete": async (_input, output) => {
      let text = output.text
      if (!text) return

      // 1) 清除正文中部「整行只有戳（可带强调包裹）」的模型复读行（含行尾换行）
      text = text.replace(new RegExp(`^[ \\t]*${WRAP}${STAMP_ANY}${WRAP}[ \\t]*\\n?`, 'gm'), '')
      // 2) 剥掉文末残留的任意戳（含强调包裹及其前导空行/缩进）
      text = text.replace(new RegExp(`(?:[ \\t]*\\n)*[ \\t]*${WRAP}${STAMP_ANY}${WRAP}[ \\t]*$`), '')
      // 3) 压掉清洗后尾部的多余空行
      text = text.replace(/\n+$/, '')

      // 4) 追加唯一权威戳（先清后追 = 天然幂等，每次执行都保证恰有一个当前时间戳）
      output.text = text ? `${text}\n\n${formatTime(new Date())}` : formatTime(new Date())
    }
  }
}) satisfies Plugin
