// A soft two-tone ring made with WebAudio, so there is no audio file to ship.
// Browsers only allow sound after a user gesture, so the context is unlocked on
// the first click anywhere in the app.

let context: AudioContext | null = null
let timer: ReturnType<typeof setInterval> | undefined

export function unlockAudio() {
  try {
    context ??= new AudioContext()
    void context.resume()
  } catch {
    // No WebAudio: ring silently.
  }
}

function tone(frequency: number, start: number) {
  if (!context) return
  const oscillator = context.createOscillator()
  const gain = context.createGain()
  oscillator.frequency.value = frequency
  gain.gain.setValueAtTime(0.0001, start)
  gain.gain.exponentialRampToValueAtTime(0.15, start + 0.04)
  gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.45)
  oscillator.connect(gain).connect(context.destination)
  oscillator.start(start)
  oscillator.stop(start + 0.5)
}

function ring() {
  if (context) {
    const now = context.currentTime
    tone(660, now)
    tone(880, now + 0.5)
  }
  // Browsers refuse vibration before the user has interacted with the page.
  if (navigator.userActivation?.hasBeenActive ?? true) navigator.vibrate?.([400, 200, 400])
}

export function startRinging() {
  stopRinging()
  ring()
  timer = setInterval(ring, 2500)
}

export function stopRinging() {
  clearInterval(timer)
  timer = undefined
}
