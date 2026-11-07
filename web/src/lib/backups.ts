// Pure helpers for the System page "Backups" card (kept free of React so they
// can be unit tested with node --test).

import type { AdminBackups, BackupConfigSummary, BackupRun } from './types'

export function describeEncryption(e: BackupConfigSummary['encryption'] | undefined): { text: string; tone: 'green' | 'red' | 'grey' } {
  switch (e) {
    case 'age-x25519':
      return { text: 'Encrypted (age public key)', tone: 'green' }
    case 'age-scrypt':
      return { text: 'Encrypted (age passphrase)', tone: 'green' }
    case 'none':
      return { text: 'Not encrypted', tone: 'red' }
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
  const m = w.match(/(docker compose --profile backup [\w -]+?)(?=\)|\.\s|$)|(\.\/scripts\/[\w.-]+)/)
  return m ? { message: w, command: m[1] ?? m[2] } : { message: w }
}
