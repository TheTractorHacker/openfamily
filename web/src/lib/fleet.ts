// Fleet health classification. Pure functions so they can be unit-tested.
// Nothing here touches coordinates: it works on liveness and OS-state facts only.

import type { FleetDevice, FleetMember } from './types'

export type Health = 'ok' | 'warn' | 'bad' | 'unknown'

export interface Finding {
  level: Health
  text: string
  /** Plain-words next step for the admin or the member. */
  hint?: string
}

const HOUR = 3_600_000

/** Findings for one phone, worst first. `now` is injected for tests. */
export function deviceFindings(d: FleetDevice, now: number, activityAt?: string | null): Finding[] {
  const out: Finding[] = []
  // activityAt: for a Private-circle member, the newest encrypted update or live connection. Their
  // uploads never touch devices.last_seen on older servers, so a working phone must not look dead.
  const times = [d.last_seen, activityAt].map((t) => (t ? new Date(t).getTime() : NaN)).filter((n) => !Number.isNaN(n))
  const seen = times.length ? Math.max(...times) : NaN
  if (Number.isNaN(seen)) out.push({ level: 'bad', text: 'Has never reported', hint: 'Ask them to open the app once while online.' })
  else if (now - seen > 24 * HOUR) out.push({ level: 'bad', text: 'Not seen for over a day', hint: 'Phone may be off, offline or signed out. Ask them to open Orbitly.' })
  else if (now - seen > 4 * HOUR) out.push({ level: 'warn', text: 'Quiet for several hours', hint: 'Usually the phone is locked or asleep. Check again later.' })

  if (d.loc_permission === 'denied') out.push({ level: 'bad', text: 'Location permission denied', hint: 'In phone Settings, give Orbitly location access set to Always.' })
  else if (d.loc_permission === 'while_in_use') out.push({ level: 'warn', text: 'Location only while the app is open', hint: 'In phone Settings, change Orbitly location to Always.' })
  if (d.notif_permission === 'denied') out.push({ level: 'warn', text: 'Notifications blocked', hint: 'Allow notifications for Orbitly in phone Settings so alerts arrive.' })
  if (d.battery_opt === 'restricted') out.push({ level: 'bad', text: 'Battery restricted: background work is blocked', hint: 'Set Orbitly battery use to Unrestricted in Android app settings.' })
  else if (d.battery_opt === 'optimized') out.push({ level: 'warn', text: 'Battery optimisation may pause tracking', hint: 'Set Orbitly battery use to Unrestricted in Android app settings.' })
  if (d.bg_service === false) out.push({ level: 'warn', text: 'Background service not running', hint: 'Open the app once; allow it to run in the background.' })
  if (d.outbox_pending != null && d.outbox_pending >= 50) out.push({ level: 'warn', text: `${d.outbox_pending} points waiting to upload`, hint: 'The phone is offline or the server is unreachable; they upload when it reconnects.' })
  if (!d.push_registered) out.push({ level: 'warn', text: 'No push channel registered', hint: 'Open the app and allow notifications; on Android install a UnifiedPush app such as ntfy.' })
  else if (d.last_push_fail_at) {
    const fail = new Date(d.last_push_fail_at).getTime()
    const ok = d.last_push_ok_at ? new Date(d.last_push_ok_at).getTime() : 0
    if (fail > ok) out.push({ level: 'warn', text: 'Last push attempt failed', hint: 'Check System health and the phone push setup.' })
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
    const f = deviceFindings(d, now, m.in_private_circle ? m.last_activity_at : null)
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

/** Best known app version: what the phone reported, else what the server last saw it send. */
export function bestVersion(d: FleetDevice): string {
  const v = d.app_version && d.app_version !== '0.1.0' ? d.app_version : d.client_version || d.app_version
  return v || 'Unknown'
}

/** Why there is no health report from this phone, in plain words. */
export function reportNote(d: FleetDevice): string {
  if (d.diag_reported_at) return ''
  const v = /^v?(\d+)\.(\d+)/.exec(bestVersion(d))
  const older = v != null && (Number(v[1]) === 0 && Number(v[2]) < 19)
  return older
    ? 'This app version is older than the health report feature. Ask them to update the app.'
    : 'The app has not sent a health report yet. It sends one when it is opened, so ask them to open the app.'
}
