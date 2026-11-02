// Small formatting helpers used across pages.

export function formatRelativeTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  const ts = new Date(iso).getTime()
  if (Number.isNaN(ts)) return '—'
  const now = Date.now()
  const diff = Math.max(0, now - ts)
  const sec = Math.round(diff / 1000)
  if (sec < 60) return `${sec}s ago`
  const min = Math.round(sec / 60)
  if (min < 60) return `${min}m ago`
  const hr = Math.round(min / 60)
  if (hr < 24) return `${hr}h ago`
  const day = Math.round(hr / 24)
  if (day < 30) return `${day}d ago`
  const mo = Math.round(day / 30)
  if (mo < 12) return `${mo}mo ago`
  const yr = Math.round(mo / 12)
  return `${yr}y ago`
}

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
}

export function formatBattery(pct: number | null | undefined): string {
  if (pct === null || pct === undefined) return '—'
  return `${Math.round(pct)}%`
}

export function formatSpeed(mps: number | null | undefined): string {
  if (mps === null || mps === undefined) return '—'
  const kmh = mps * 3.6
  return `${kmh.toFixed(0)} km/h`
}

export function formatAccuracy(m: number | null | undefined): string {
  if (m === null || m === undefined) return '—'
  if (m < 1000) return `±${Math.round(m)} m`
  return `±${(m / 1000).toFixed(1)} km`
}

export function motionLabel(state: string | null | undefined): string {
  if (!state) return 'Unknown'
  return state.charAt(0).toUpperCase() + state.slice(1)
}

export function initialsOf(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return '?'
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}
/** "in 3h" / "in 2d" for a future timestamp; "expired" once it has passed. */
export function formatTimeLeft(iso: string | null | undefined): string {
  if (!iso) return '—'
  const ts = new Date(iso).getTime()
  if (Number.isNaN(ts)) return '—'
  const sec = Math.round((ts - Date.now()) / 1000)
  if (sec <= 0) return 'expired'
  if (sec < 60) return `in ${sec}s`
  const min = Math.round(sec / 60)
  if (min < 60) return `in ${min}m`
  const hr = Math.round(min / 60)
  if (hr < 24) return `in ${hr}h`
  return `in ${Math.round(hr / 24)}d`
}
