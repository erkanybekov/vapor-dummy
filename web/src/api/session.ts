import type { User } from './types'

// The signed-in session, persisted in localStorage and shared by every tab.
// Refresh tokens are single-use (the server revokes the old one on refresh), so
// tabs must see each other's refreshes: the `storage` event keeps them in sync.

export interface Session {
  accessToken: string
  refreshToken: string
  user: User
}

const STORAGE_KEY = 'vapor.session'

type Listener = () => void

export function readStoredSession(): Session | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    return raw ? (JSON.parse(raw) as Session) : null
  } catch {
    return null
  }
}

let current: Session | null = readStoredSession()
const listeners = new Set<Listener>()

function emit() {
  listeners.forEach((listener) => listener())
}

export const sessionStore = {
  get(): Session | null {
    return current
  },

  set(next: Session | null) {
    current = next
    try {
      if (next) localStorage.setItem(STORAGE_KEY, JSON.stringify(next))
      else localStorage.removeItem(STORAGE_KEY)
    } catch {
      // Storage can be unavailable (private mode); the session then lives in memory only.
    }
    emit()
  },

  updateUser(user: User) {
    if (current) sessionStore.set({ ...current, user })
  },

  subscribe(listener: Listener): () => void {
    listeners.add(listener)
    return () => listeners.delete(listener)
  },
}

if (typeof window !== 'undefined') {
  window.addEventListener('storage', (event) => {
    if (event.key !== STORAGE_KEY) return
    current = readStoredSession()
    emit()
  })
}
