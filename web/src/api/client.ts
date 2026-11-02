import { readStoredSession, sessionStore, type Session } from './session'
import type { AuthResponse } from './types'

export const API_BASE = '/api/v1'

/** Refresh this long before the access token expires. */
const REFRESH_MARGIN_MS = 60_000

export class ApiError extends Error {
  /** HTTP status, or 0 when the server could not be reached. */
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

export function sessionFromAuth(response: AuthResponse): Session {
  return { accessToken: response.accessToken, refreshToken: response.refreshToken, user: response.user }
}

/** Expiry of a JWT in ms since epoch, or 0 if it cannot be read. */
export function tokenExpiry(token: string): number {
  try {
    const payload = token.split('.')[1] ?? ''
    const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'))
    const exp = (JSON.parse(json) as { exp?: number }).exp
    return typeof exp === 'number' ? exp * 1000 : 0
  } catch {
    return 0
  }
}

async function errorFrom(response: Response): Promise<ApiError> {
  let reason: string | undefined
  try {
    reason = ((await response.json()) as { reason?: string }).reason
  } catch {
    // Not JSON (e.g. a proxy error page).
  }
  return new ApiError(response.status, reason ?? `Ошибка сервера (${response.status})`)
}

async function send(path: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(`${API_BASE}${path}`, init)
  } catch {
    throw new ApiError(0, 'Нет связи с сервером')
  }
}

// Single-flight refresh: concurrent callers share one request, because using the
// same refresh token twice fails (the first use revokes it).
let refreshInFlight: Promise<Session> | null = null

export function refreshSession(): Promise<Session> {
  refreshInFlight ??= performRefresh().finally(() => {
    refreshInFlight = null
  })
  return refreshInFlight
}

async function performRefresh(): Promise<Session> {
  const session = sessionStore.get()
  if (!session) throw new ApiError(401, 'Нужно войти')

  const response = await send('/auth/refresh', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refreshToken: session.refreshToken }),
  })

  if (!response.ok) {
    // Another tab may have rotated the refresh token a moment ago.
    const stored = readStoredSession()
    if (stored && stored.refreshToken !== session.refreshToken) {
      sessionStore.set(stored)
      return stored
    }
    if (response.status === 401 || response.status === 403) sessionStore.set(null)
    throw await errorFrom(response)
  }

  const next = sessionFromAuth((await response.json()) as AuthResponse)
  sessionStore.set(next)
  return next
}

/** A valid access token, refreshed first if it is about to expire. */
export async function getAccessToken(): Promise<string> {
  const session = sessionStore.get()
  if (!session) throw new ApiError(401, 'Нужно войти')
  if (tokenExpiry(session.accessToken) - Date.now() > REFRESH_MARGIN_MS) return session.accessToken
  return (await refreshSession()).accessToken
}

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
  body?: unknown
  /** Send the access token (default). */
  auth?: boolean
}

export async function api<T>(path: string, { method = 'GET', body, auth = true }: RequestOptions = {}): Promise<T> {
  const request = (token?: string) => {
    const headers: Record<string, string> = {}
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    if (token) headers.Authorization = `Bearer ${token}`
    return send(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) })
  }

  let response = await request(auth ? await getAccessToken() : undefined)

  // The token can be rejected before its expiry (revoked, server secret rotated):
  // refresh once and retry.
  if (auth && response.status === 401) {
    response = await request((await refreshSession()).accessToken)
  }

  if (!response.ok) throw await errorFrom(response)
  return (await response.json()) as T
}
