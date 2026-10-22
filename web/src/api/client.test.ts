import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// The client module reads localStorage when it loads, so each test stubs the
// browser globals first and then imports a fresh copy of the modules.

function token(expiresInSeconds: number, id = Math.random().toString(36).slice(2)): string {
  const payload = btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + expiresInSeconds, jti: id }))
  return `header.${payload}.signature`
}

function memoryStorage(initial: Record<string, string> = {}) {
  const data = new Map(Object.entries(initial))
  return {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
    removeItem: (key: string) => void data.delete(key),
  }
}

const user = { id: 'u1', email: 'me@example.com', username: 'me', isActive: true }

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

async function setup(session: { accessToken: string; refreshToken: string }) {
  const storage = memoryStorage({ 'vapor.session': JSON.stringify({ ...session, user }) })
  vi.stubGlobal('localStorage', storage)
  const fetchMock = vi.fn<(url: string, init?: RequestInit) => Promise<Response>>()
  vi.stubGlobal('fetch', fetchMock)
  vi.resetModules()
  const client = await import('./client')
  const { sessionStore } = await import('./session')
  return { client, sessionStore, fetchMock, storage }
}

function authorization(init?: RequestInit): string | undefined {
  return (init?.headers as Record<string, string> | undefined)?.Authorization
}

beforeEach(() => {
  vi.unstubAllGlobals()
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('api client', () => {
  it('uses the stored access token while it is valid', async () => {
    const access = token(3600)
    const { client, fetchMock } = await setup({ accessToken: access, refreshToken: 'r1' })
    fetchMock.mockResolvedValue(json(200, { ok: true }))

    await client.api('/todos')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(authorization(fetchMock.mock.calls[0]?.[1])).toBe(`Bearer ${access}`)
  })

  it('refreshes an expiring token once for concurrent requests', async () => {
    const fresh = token(3600)
    const { client, fetchMock, sessionStore } = await setup({ accessToken: token(10), refreshToken: 'r1' })
    fetchMock.mockImplementation(async (url) =>
      url.endsWith('/auth/refresh')
        ? json(200, { accessToken: fresh, refreshToken: 'r2', expiresIn: 3600, tokenType: 'Bearer', user })
        : json(200, { ok: true }),
    )

    await Promise.all([client.api('/todos'), client.api('/calls/history'), client.api('/auth/me')])

    const refreshes = fetchMock.mock.calls.filter(([url]) => url.endsWith('/auth/refresh'))
    expect(refreshes).toHaveLength(1)
    const others = fetchMock.mock.calls.filter(([url]) => !url.endsWith('/auth/refresh'))
    expect(others.map(([, init]) => authorization(init))).toEqual([`Bearer ${fresh}`, `Bearer ${fresh}`, `Bearer ${fresh}`])
    expect(sessionStore.get()?.refreshToken).toBe('r2')
  })

  it('refreshes and retries once when a request gets 401', async () => {
    const fresh = token(3600)
    const { client, fetchMock } = await setup({ accessToken: token(3600), refreshToken: 'r1' })
    fetchMock
      .mockResolvedValueOnce(json(401, { error: true, reason: 'Authentication required' }))
      .mockResolvedValueOnce(json(200, { accessToken: fresh, refreshToken: 'r2', expiresIn: 3600, tokenType: 'Bearer', user }))
      .mockResolvedValueOnce(json(200, { todos: [] }))

    await expect(client.api('/todos')).resolves.toEqual({ todos: [] })
    expect(authorization(fetchMock.mock.calls[2]?.[1])).toBe(`Bearer ${fresh}`)
  })

  it('signs out when the refresh token is rejected', async () => {
    const { client, fetchMock, sessionStore } = await setup({ accessToken: token(10), refreshToken: 'revoked' })
    fetchMock.mockResolvedValue(json(401, { error: true, reason: 'Invalid token' }))

    await expect(client.api('/todos')).rejects.toMatchObject({ status: 401, message: 'Invalid token' })
    expect(sessionStore.get()).toBeNull()
  })

  it('adopts a session another tab refreshed instead of signing out', async () => {
    const { client, fetchMock, sessionStore, storage } = await setup({ accessToken: token(10), refreshToken: 'r1' })
    const otherTabAccess = token(3600)
    fetchMock.mockImplementation(async (url) => {
      if (url.endsWith('/auth/refresh')) {
        // The other tab used r1 first and stored r2.
        storage.setItem('vapor.session', JSON.stringify({ accessToken: otherTabAccess, refreshToken: 'r2', user }))
        return json(401, { error: true, reason: 'Token has been revoked' })
      }
      return json(200, { ok: true })
    })

    await client.api('/todos')

    expect(sessionStore.get()?.refreshToken).toBe('r2')
    expect(authorization(fetchMock.mock.calls.at(-1)?.[1])).toBe(`Bearer ${otherTabAccess}`)
  })

  it('reports an unreachable server as status 0', async () => {
    const { client, fetchMock } = await setup({ accessToken: token(3600), refreshToken: 'r1' })
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'))

    await expect(client.api('/todos')).rejects.toMatchObject({ status: 0 })
  })
})
