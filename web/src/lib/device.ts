// Device identity for call signaling. Each browser tab is its own device (so two
// tabs can call each other), and the id survives reloads so the server can
// resume a call after a refresh mid-call.

function uuid(): string {
  // crypto.randomUUID needs a secure context; getRandomValues works everywhere.
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

export const deviceId: string = (() => {
  try {
    const stored = sessionStorage.getItem('vapor.deviceId')
    if (stored) return stored
    const id = uuid()
    sessionStorage.setItem('vapor.deviceId', id)
    return id
  } catch {
    return uuid()
  }
})()

export const deviceName: string = (() => {
  const ua = navigator.userAgent
  const os = /iPhone/.test(ua)
    ? 'iPhone'
    : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)
      ? 'iPad'
      : /Android/.test(ua)
        ? 'Android'
        : /Macintosh/.test(ua)
          ? 'Mac'
          : /Windows/.test(ua)
            ? 'Windows'
            : 'Компьютер'
  const browser = /Edg\//.test(ua)
    ? 'Edge'
    : /Firefox|FxiOS/.test(ua)
      ? 'Firefox'
      : /Chrome|CriOS/.test(ua)
        ? 'Chrome'
        : /Safari/.test(ua)
          ? 'Safari'
          : 'Browser'
  return `${os} · ${browser}`
})()

export const isMobile = /iPhone|iPad|Android/.test(navigator.userAgent)
