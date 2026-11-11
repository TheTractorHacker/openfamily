/** Plain-words status of the Dawarich sync, from the fields the server stores. */

export interface DawarichHealthFields {
  last_error: string
  failures: number
  next_retry_at: string | null
  last_ok_at: string | null
}

/** "5m ago", "3h ago", "never". */
export function agoText(iso: string | null, now: number = Date.now()): string {
  if (!iso) return 'never'
  const secs = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000))
  if (secs < 60) return 'just now'
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`
  return `${Math.floor(secs / 86400)}d ago`
}

/** "in 4 minutes", "in 1 hour", or "on the next check" once the time has passed. */
export function retryText(iso: string | null, now: number = Date.now()): string {
  if (!iso) return 'soon'
  const secs = Math.round((new Date(iso).getTime() - now) / 1000)
  if (secs <= 60) return 'on the next check'
  const mins = Math.round(secs / 60)
  if (mins < 60) return `in ${mins} minute${mins === 1 ? '' : 's'}`
  const hours = Math.round(mins / 60)
  return `in ${hours} hour${hours === 1 ? '' : 's'}`
}

/**
 * The message shown under the Dawarich card, or null when the sync is healthy.
 * It says what failed, how long it has been failing, when the next try is, and
 * when something last arrived, so an outage is not just a stale timestamp.
 */
export function dawarichProblem(s: DawarichHealthFields, now: number = Date.now()): string | null {
  if (!s.last_error) return null
  const tries = s.failures > 1 ? ` after ${s.failures} tries in a row` : ''
  const retry = s.failures > 0 ? ` Trying again ${retryText(s.next_retry_at, now)}; “Sync now” tries at once.` : ''
  return `Not reaching Dawarich${tries}: ${s.last_error}.${retry} Last delivery: ${agoText(s.last_ok_at, now)}.`
}
