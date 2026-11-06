// Fleet health classification. Pure functions so they can be unit-tested.
// Nothing here touches coordinates: it works on liveness and OS-state facts only.

import type { FleetDevice, FleetMember } from './types'

export type Health = 'ok' | 'warn' | 'bad' | 'unknown'

export interface Finding {
  level: Health
  text: string
}

const HOUR = 3_600_000

/** Findings for one phone, worst first. `now` is injected for tests. */
export function deviceFindings(d: FleetDevice, now: number): Finding[] {
  const out: Finding[] = []
  const seen = d.last_seen ? new Date(d.last_seen).getTime() : NaN
  if (Number.isNaN(seen)) out.push({ level: 'bad', text: 'Has never reported' })
  else if (now - seen > 24 * HOUR) out.push({ level: 'bad', text: 'Not seen for over a day' })
  else if (now - seen > 4 * HOUR) out.push({ level: 'warn', text: 'Quiet for several hours' })

  if (d.loc_permission === 'denied') out.push({ level: 'bad', text: 'Location permission denied' })
  else if (d.loc_permission === 'while_in_use') out.push({ level: 'warn', text: 'Location only while the app is open' })
  if (d.notif_permission === 'denied') out.push({ level: 'warn', text: 'Notifications blocked' })
  if (d.battery_opt === 'restricted') out.push({ level: 'bad', text: 'Battery restricted: background work is blocked' })
  else if (d.battery_opt === 'optimized') out.push({ level: 'warn', text: 'Battery optimisation may pause tracking' })
  if (d.bg_service === false) out.push({ level: 'warn', text: 'Background service not running' })
  if (d.outbox_pending != null && d.outbox_pending >= 50) out.push({ level: 'warn', text: `${d.outbox_pending} points waiting to upload` })
  if (!d.push_registered) out.push({ level: 'warn', text: 'No push channel registered' })
  else if (d.last_push_fail_at) {
    const fail = new Date(d.last_push_fail_at).getTime()
    const ok = d.last_push_ok_at ? new Date(d.last_push_ok_at).getTime() : 0
    if (fail > ok) out.push({ level: 'warn', text: 'Last push attempt failed' })
  }
  const rank = { bad: 0, warn: 1, unknown: 2, ok: 3 } as const
  return out.sort((a, b) => rank[a.level] - rank[b.level])
}

/** Overall health of a member: the worst of their phones' best-case state. */
export function memberHealth(m: FleetMember, now: number): Health {
  if (m.devices.length === 0) return 'unknown'
  // A member is as healthy as their healthiest phone: families often keep an old spare.
  let best: Health = 'bad'
  const rank = { ok: 0, warn: 1, bad: 2, unknown: 3 } as const
  for (const d of m.devices) {
    const f = deviceFindings(d, now)
    const level: Health = f.some((x) => x.level === 'bad') ? 'bad' : f.length > 0 ? 'warn' : 'ok'
    if (rank[level] < rank[best]) best = level
  }
  return best
}

export function summarize(members: FleetMember[], now: number) {
  const s = { total: members.length, ok: 0, warn: 0, bad: 0, unknown: 0, devices: 0, noPush: 0, pendingPoints: 0 }
  for (const m of members) {
    s[memberHealth(m, now)]++
    for (const d of m.devices) {
      s.devices++
      if (!d.push_registered) s.noPush++
      s.pendingPoints += d.outbox_pending ?? 0
    }
  }
  return s
}

export function batteryLabel(v: FleetDevice['battery_opt']): string {
  switch (v) {
    case 'unrestricted':
      return 'Unrestricted'
    case 'optimized':
      return 'Optimised'
    case 'restricted':
      return 'Restricted'
    default:
      return 'Not reported'
  }
}
