import { createContext, useCallback, useContext, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from 'react'
import { ApiError, sessionFromAuth } from '../api/client'
import { authApi } from '../api/endpoints'
import { sessionStore } from '../api/session'
import type { User } from '../api/types'

interface AuthValue {
  user: User | null
  /** True while a stored session is being validated on startup. */
  checking: boolean
  login: (email: string, password: string) => Promise<void>
  register: (email: string, username: string, password: string) => Promise<void>
  logout: () => Promise<void>
}

const AuthContext = createContext<AuthValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const session = useSyncExternalStore(sessionStore.subscribe, sessionStore.get)
  const [checking, setChecking] = useState(() => sessionStore.get() !== null)

  // Validate a stored session once. Only a definite 401 signs out: a sleeping
  // or unreachable server must not throw the user out.
  useEffect(() => {
    if (!sessionStore.get()) return
    let cancelled = false
    authApi
      .me()
      .then((user) => {
        if (!cancelled) sessionStore.updateUser(user)
      })
      .catch((error: unknown) => {
        if (error instanceof ApiError && error.status === 401) sessionStore.set(null)
      })
      .finally(() => {
        if (!cancelled) setChecking(false)
      })
    return () => {
      cancelled = true
    }
  }, [])

  const login = useCallback(async (email: string, password: string) => {
    sessionStore.set(sessionFromAuth(await authApi.login(email, password)))
  }, [])

  const register = useCallback(async (email: string, username: string, password: string) => {
    sessionStore.set(sessionFromAuth(await authApi.register(email, username, password)))
  }, [])

  const logout = useCallback(async () => {
    try {
      await authApi.logout()
    } catch {
      // Signing out locally is what matters.
    }
    sessionStore.set(null)
  }, [])

  const value = useMemo(
    () => ({ user: session?.user ?? null, checking, login, register, logout }),
    [session, checking, login, register, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthValue {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth must be used inside <AuthProvider>')
  return value
}
