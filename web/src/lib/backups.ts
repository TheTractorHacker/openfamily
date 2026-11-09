// Pure helpers for the Settings > Backups card (kept free of React so they
// can be unit tested with node --test).

import type { AdminBackups, BackupConfigSummary, BackupRun } from './types'

export function describeEncryption(e: BackupConfigSummary['encryption'] | undefined): { text: string; tone: 'green' | 'orange' | 'grey' } {
  switch (e) {
    case 'age-x25519':
      return { text: 'Encrypted (age public key)', tone: 'green' }
    case 'age-scrypt':
      return { text: 'Encrypted (age passphrase)', tone: 'green' }
    case 'none':
      return { text: 'Not encrypted', tone: 'orange' }
    default:
      return { text: 'Unknown', tone: 'grey' }
  }
}

export function describeRetention(r: BackupConfigSummary['retention'] | undefined): string {
  if (!r) return '—'
  if (r.daily === 0 && r.weekly === 0 && r.monthly === 0) return 'Keep everything (pruning off)'
  const parts: string[] = []
  if (r.daily) parts.push(`${r.daily} daily`)
  if (r.weekly) parts.push(`${r.weekly} weekly`)
  if (r.monthly) parts.push(`${r.monthly} monthly`)
  return parts.join(' · ') + (r.dry_run ? ' (dry run: nothing is deleted)' : '')
}

export function describeDuration(ms: number | null | undefined): string {
  if (ms == null || ms < 0) return ''
  if (ms < 1000) return `${ms} ms`
  const s = Math.round(ms / 1000)
  if (s < 60) return `${s}s`
  return `${Math.floor(s / 60)}m ${s % 60}s`
}

export function requestInFlight(b: Pick<AdminBackups, 'request'>): boolean {
  return b.request?.status === 'pending' || b.request?.status === 'running'
}

/** Human label for a destination kind. */
export function destinationLabel(kind: string): string {
  return kind === 's3' ? 'S3' : kind === 'local' ? 'Local disk' : kind
}

export function runSummary(r: BackupRun, size: (n: number) => string): string {
  const bits = [destinationLabel(r.destination), r.status === 'success' ? size(r.size_bytes) : 'failed']
  const d = describeDuration(r.duration_ms)
  if (d) bits.push(d)
  bits.push(r.trigger)
  return bits.join(' · ')
}

/** Splits a server warning into its prose and an embedded runnable command, if any. */
export function splitWarning(w: string): { message: string; command?: string } {
  const m = w.match(/(docker compose (?:--profile backup )?(?:up|ps|logs|restart)[\w -]*?)(?=\)|\.\s|$)|(\.\/scripts\/[\w.-]+)/)
  return m ? { message: w, command: m[1] ?? m[2] } : { message: w }
}

// ---- settings form helpers ----

import type { BackupSettingsValues } from './types'

const DAILY = /^(\d{1,2}) (\d{1,2}) \* \* \*$/

/** "HH:MM" for a plain daily cron, or null when the schedule needs the advanced field. */
export function cronToDaily(cron: string): string | null {
  const m = cron.trim().match(DAILY)
  if (!m) return null
  const min = Number(m[1])
  const hour = Number(m[2])
  if (min > 59 || hour > 23) return null
  return `${String(hour).padStart(2, '0')}:${String(min).padStart(2, '0')}`
}

export function dailyToCron(hhmm: string): string | null {
  const m = hhmm.match(/^(\d{1,2}):(\d{2})$/)
  if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return null
  return `${Number(m[2])} ${Number(m[1])} * * *`
}

/** Light client-side checks; the server validates everything again. */
export function validateForm(v: BackupSettingsValues, pinned: Set<string>): Record<string, string> {
  const e: Record<string, string> = {}
  const p = (f: string) => pinned.has(f)
  if (v.s3_enabled && !p('bucket') && !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(v.bucket)) e.bucket = '3-63 characters: lowercase letters, digits, dots, dashes'
  if (v.s3_enabled && !p('endpoint') && v.endpoint) {
    if (/^http:\/\//i.test(v.endpoint) && !v.insecure) e.endpoint = 'Plain http is refused. Use https, or allow plain HTTP for a MinIO on your own network.'
    else if (/[\s@]/.test(v.endpoint) || /\/\/[^/]*\/./.test(v.endpoint)) e.endpoint = 'Enter a host or https URL without a path or credentials'
  }
  for (const k of v.age_recipients) {
    if (k.startsWith('AGE-SECRET-KEY-')) e.age_recipients = 'That is a PRIVATE key. Never paste it here; enter the public key (age1...).'
    else if (!/^age1[a-z0-9]{58}$/.test(k)) e.age_recipients = 'Not a valid age public key (age1...)'
  }
  if (!p('schedule') && v.schedule.trim().split(/\s+/).length !== 5) e.schedule = 'Five fields: minute hour day month weekday'
  for (const [k, max] of [['keep_daily', 3650], ['keep_weekly', 3650], ['keep_monthly', 3650]] as const) {
    if (!p(k) && (!Number.isInteger(v[k]) || v[k] < 0 || v[k] > max)) e[k] = '0 to 3650'
  }
  if (!p('stale_hours') && (!Number.isInteger(v.stale_hours) || v.stale_hours < 1 || v.stale_hours > 8760)) e.stale_hours = '1 to 8760'
  return e
}

export function parseRecipients(text: string): string[] {
  return text.split(/[\s,]+/).map((s) => s.trim()).filter(Boolean)
}

/** Saved credentials only work for the destination they were saved for. */
export function credsBindingChanged(
  saved: Pick<BackupSettingsValues, 'endpoint' | 'insecure' | 'allow_private' | 'region'>,
  cur: Pick<BackupSettingsValues, 'endpoint' | 'insecure' | 'allow_private' | 'region'>,
): boolean {
  const ep = (e: string) => e.trim().toLowerCase().replace(/\/+$/, '')
  return ep(saved.endpoint) !== ep(cur.endpoint) || saved.insecure !== cur.insecure || saved.allow_private !== cur.allow_private || saved.region.trim() !== cur.region.trim()
}

export const REENTER_CREDENTIALS = 'Re-enter the access key and secret because the endpoint changed.'
