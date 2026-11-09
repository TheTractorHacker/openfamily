// Pure helpers for privateViewer.ts (kept separate so tests run without React).

/** Owner decision D4: an unlocked account key locks after 30 minutes without activity. */
export const IDLE_LOCK_MS = 30 * 60 * 1000

/** Should an unlocked account key be locked now? */
export function idleExpired(now: number, last: number, limit = IDLE_LOCK_MS): boolean {
  return now - last >= limit
}
