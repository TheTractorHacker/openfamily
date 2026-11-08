// Identity + capability store for the signed-in account.
//
// The web panel serves two audiences: platform admins (server-wide surfaces)
// and regular users, whose permissions mirror the mobile apps (everything
// scoped to their own family). Pages ask this hook "who is signed in and what
// may they do" instead of probing admin endpoints and catching 403s.

import React from 'react'
import { whoAmI } from './api'
import { getAccessToken, subscribeAuth } from './auth'
import type { Me } from './types'

let cache: Me | null = null
let inflight: Promise<Me> | null = null

function invalidate(): void {
  cache = null
  inflight = null
}

/** Fetches the signed-in identity once per session; cached afterwards. */
export function loadMe(force = false): Promise<Me> {
  if (!getAccessToken()) {
    invalidate()
    return Promise.reject(new Error('Not signed in'))
  }
  if (!force && cache) return Promise.resolve(cache)
  if (!inflight) {
    inflight = whoAmI()
      .then((me) => {
        cache = me
        return me
      })
      .catch((e) => {
        // A rejected /me means our tokens are dead — drop them so the shell
        // falls back to the login screen instead of looping.
        if (e instanceof Error && e.message === 'Not signed in') throw e
        invalidate()
        throw e
      })
    inflight.finally(() => {
      inflight = null
    })
  }
  return inflight
}

// Cross-tab login/logout invalidates the cached identity.
if (typeof window !== 'undefined') {
  subscribeAuth(() => {
    if (!getAccessToken()) invalidate()
    // Sign-in or sign-out in this tab: every mounted consumer re-fetches. Without
    // this the shell stayed on "Loading your account…" after a login with no reload.
    notify()
  })
  window.addEventListener('storage', (e) => {
    if (e.key === 'wb_access_token' || e.key === 'wb_refresh_token') invalidate()
  })
}

export interface UseMeResult {
  /** Signed-in account with capability flags; null while loading or signed out. */
  me: Me | null
  loading: boolean
  error: string | null
  /** Convenience flags derived from `me`. */
  isPlatformAdmin: boolean
  role: Me['role'] | null
  familyId: string | null
  /** Re-fetches the identity (e.g. after joining or leaving a family). */
  refresh: () => void
}

const listeners = new Set<() => void>()
let bump = 0

function notify(): void {
  bump += 1
  listeners.forEach((l) => l())
}

/** Forces a re-fetch of the identity and notifies every useMe consumer. */
export function refreshMe(): void {
  invalidate()
  notify()
}

export function useMe(): UseMeResult {
  // `version` mirrors the module-level bump counter so a refresh() re-runs
  // the fetch effect in every mounted consumer.
  const [version, setVersion] = React.useState(bump)
  const [error, setError] = React.useState<string | null>(null)
  const [loading, setLoading] = React.useState(cache === null)

  React.useEffect(() => {
    const listener = () => setVersion(bump)
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  }, [])

  React.useEffect(() => {
    let cancelled = false
    setError(null)
    setLoading(cache === null)
    loadMe()
      .then(() => {
        if (!cancelled) setLoading(false)
      })
      .catch((e) => {
        if (cancelled) return
        if (!getAccessToken()) {
          setLoading(false)
          return
        }
        setError(e instanceof Error ? e.message : 'Could not load your account')
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [version])

  const me = getAccessToken() ? cache : null
  return {
    me,
    loading,
    error,
    isPlatformAdmin: me?.platform_admin ?? false,
    role: me?.role ?? null,
    familyId: me?.family_id ?? null,
    refresh: refreshMe,
  }
}
