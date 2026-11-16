// Auth store — persists tokens in localStorage and exposes a tiny reactive
// subscription so the App can re-render on login/logout.

import type { LoginResponse } from './types'

const ACCESS_KEY = 'wb_access_token'
const REFRESH_KEY = 'wb_refresh_token'
const EMAIL_KEY = 'wb_email'

type Listener = () => void

const listeners = new Set<Listener>()

function emit(): void {
  listeners.forEach((l) => l())
}

export function getAccessToken(): string | null {
  try {
    return localStorage.getItem(ACCESS_KEY)
  } catch {
    return null
  }
}

export function getRefreshToken(): string | null {
  try {
    return localStorage.getItem(REFRESH_KEY)
  } catch {
    return null
  }
}

export function setTokens(tokens: LoginResponse): void {
  try {
    localStorage.setItem(ACCESS_KEY, tokens.access_token)
    localStorage.setItem(REFRESH_KEY, tokens.refresh_token)
  } catch {
    // storage may be unavailable (private mode) — non-fatal
  }
  emit()
}

export function setEmail(email: string): void {
  try {
    localStorage.setItem(EMAIL_KEY, email)
  } catch {
    // ignore
  }
  emit()
}

export function getEmail(): string | null {
  try {
    return localStorage.getItem(EMAIL_KEY)
  } catch {
    return null
  }
}

export function clearTokens(): void {
  try {
    localStorage.removeItem(ACCESS_KEY)
    localStorage.removeItem(REFRESH_KEY)
    localStorage.removeItem(EMAIL_KEY)
  } catch {
    // ignore
  }
  emit()
}

/**
 * Signs out: revokes only this browser's server-side session (its refresh
 * family), then clears local storage. Best effort with a short timeout -- local
 * sign-out always happens. POST /auth/logout is deliberately not used: it
 * would sign the user's phones out too.
 */
export async function signOut(fetchImpl: typeof fetch = fetch): Promise<void> {
  try {
    await Promise.race([
      revokeCurrentSession(fetchImpl),
      new Promise<void>((resolve) => setTimeout(resolve, 4000)),
    ])
  } catch {
    // network/server failure: still sign out locally
  } finally {
    clearTokens()
  }
}

async function revokeCurrentSession(fetchImpl: typeof fetch): Promise<void> {
  const call = (method: string, path: string, body?: unknown) =>
    fetchImpl(path, {
      method,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${getAccessToken() ?? ''}`,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  const refreshToken = getRefreshToken()
  if (!refreshToken) return
  let res = await call('POST', '/auth/sessions/current', { refresh_token: refreshToken })
  if (res.status === 401) {
    // Expired access token: renew once (this rotates the stored refresh token).
    const r = await fetchImpl('/auth/refresh', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refreshToken }),
    })
    if (!r.ok) return
    setTokens((await r.json()) as LoginResponse)
    res = await call('POST', '/auth/sessions/current', { refresh_token: getRefreshToken() })
  }
  if (!res.ok) return
  const { id } = (await res.json()) as { id?: string }
  if (id) await call('DELETE', `/auth/sessions/${encodeURIComponent(id)}`)
}

/** True when the JWT is missing/unparseable or expires within `skewSec`. */
export function accessTokenStale(token: string | null, nowMs = Date.now(), skewSec = 30): boolean {
  if (!token) return true
  try {
    const part = token.split('.')[1] ?? ''
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/'))
    const exp = (JSON.parse(json) as { exp?: number }).exp
    if (typeof exp !== 'number') return true
    return exp * 1000 - nowMs < skewSec * 1000
  } catch {
    return true
  }
}

let refreshInFlight: Promise<string | null> | null = null

/**
 * Returns an access token that is not about to expire, refreshing through the
 * refresh token when needed (single-flighted). Used by long-lived consumers
 * such as the live-map WebSocket, which the server closes at token expiry.
 * Falls back to the stored token if refresh fails (e.g. offline).
 */
export function ensureFreshAccessToken(fetchImpl: typeof fetch = fetch): Promise<string | null> {
  const current = getAccessToken()
  if (!accessTokenStale(current)) return Promise.resolve(current)
  const refreshToken = getRefreshToken()
  if (!refreshToken) return Promise.resolve(current)
  if (refreshInFlight) return refreshInFlight
  refreshInFlight = (async () => {
    try {
      const r = await fetchImpl('/auth/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: refreshToken }),
      })
      if (r.ok) {
        setTokens((await r.json()) as LoginResponse)
        return getAccessToken()
      }
    } catch {
      // offline: keep the stored token
    }
    return current
  })().finally(() => {
    refreshInFlight = null
  })
  return refreshInFlight
}

export function isAuthenticated(): boolean {
  return getAccessToken() !== null
}

export function subscribeAuth(listener: Listener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

// Cross-tab logout: if another tab clears tokens, this tab reacts too.
if (typeof window !== 'undefined') {
  window.addEventListener('storage', (e) => {
    if (e.key === ACCESS_KEY || e.key === REFRESH_KEY || e.key === EMAIL_KEY) emit()
  })
}