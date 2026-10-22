const timeFormat = new Intl.DateTimeFormat('ru', { hour: '2-digit', minute: '2-digit' })
const dayFormat = new Intl.DateTimeFormat('ru', { day: 'numeric', month: 'short' })

/** "14:05", "вчера, 14:05" or "12 окт., 14:05". */
export function formatWhen(iso: string, now = new Date()): string {
  const date = new Date(iso)
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  const time = timeFormat.format(date)
  if (date.getTime() >= startOfToday) return time
  if (date.getTime() >= startOfToday - 86_400_000) return `вчера, ${time}`
  return `${dayFormat.format(date)}, ${time}`
}

/** Call length as "0:42" or "1:02:03". */
export function formatDuration(totalSeconds: number): string {
  const seconds = Math.max(0, Math.floor(totalSeconds))
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = String(seconds % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`
}

/** Russian plural: plural(5, ['задача', 'задачи', 'задач']) → "задач". */
export function plural(n: number, forms: [string, string, string]): string {
  const mod10 = n % 10
  const mod100 = n % 100
  if (mod10 === 1 && mod100 !== 11) return forms[0]
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return forms[1]
  return forms[2]
}
