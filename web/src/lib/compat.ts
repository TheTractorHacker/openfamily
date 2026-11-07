// Pure helpers for the Settings "App versions" card (kept free of React so
// they can be unit tested with node --test).

import type { AdminCompat, AdminCompatUser, AdminCompatVersion, AppCompatStatus } from './types'

export const COMPAT_TONE = { ok: 'green', recommended: 'orange', required: 'red', unknown: 'grey' } as const

export const COMPAT_LABEL: Record<AppCompatStatus, string> = {
  ok: 'Supported',
  recommended: 'Update recommended',
  required: 'Outside the window',
  unknown: 'Unknown',
}

/** True for "0.16", "0.16.0" and "v0.16.0+3"; used to validate the override field. */
export function isVersionInput(s: string): boolean {
  return /^v?\d{1,4}\.\d{1,4}(\.\d{1,4})?([+-][0-9A-Za-z.-]+)?$/.test(s.trim())
}

/** Users per status across all rows (a user on two versions counts in both rows). */
export function usersByStatus(versions: AdminCompatVersion[]): Record<AppCompatStatus, number> {
  const out: Record<AppCompatStatus, number> = { ok: 0, recommended: 0, required: 0, unknown: 0 }
  for (const v of versions) out[v.status] = (out[v.status] ?? 0) + v.users
  return out
}

/** One-line description of where the minimum version comes from. */
export function describePolicy(p: AdminCompat['policy']): string {
  const window = p.window.length ? `${p.window[0]} to ${p.window[p.window.length - 1]}` : 'none'
  switch (p.source) {
    case 'admin':
      return `Minimum ${p.min_supported_version} set by an admin (rolling window would be ${window}).`
    case 'env':
      return `Minimum ${p.min_supported_version} pinned by MIN_SUPPORTED_APP_VERSION.`
    default:
      return `Rolling window of the last ${p.window_size} releases: ${window}.`
  }
}


/** Plain-words explanation of the support rule, shown on the App versions card. */
export function policyInWords(p: AdminCompat['policy']): string {
  const first = p.window[0] ?? p.min_supported_version
  const last = p.window[p.window.length - 1] ?? p.latest_version
  return (
    `The server works with the last ${p.window_size} app versions (${first} to ${last}), so nobody has to update on the same day as the server. ` +
    `Apps 2 or more versions behind the newest still work and get a small note. Apps older than ${p.min_supported_version} get an "Update required" banner` +
    (p.enforce_writes ? ' and their location uploads are refused until they update.' : ', but their uploads are still accepted (enforcement is off).')
  )
}

/** Splits people into those who need a nudge (outside the window or behind) and the rest. */
export function peopleNeedingUpdate(people: AdminCompatUser[] = []): AdminCompatUser[] {
  return people.filter((u) => u.status === 'required' || u.status === 'recommended')
}
