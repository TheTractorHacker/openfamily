// Bubbles — a read-only list of active Bubbles (temporary per-person
// geofences) across every family, with the members of the circle each one
// belongs to. Coordinates are deliberately not shown.

import { listAdminBubbles } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import './pages.css'
import './ActivityPage.css'

function formatRadius(m: number): string {
  return m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${m} m`
}

function formatExpiry(iso: string): string {
  const ms = new Date(iso).getTime() - Date.now()
  if (Number.isNaN(ms) || ms <= 0) return 'expired'
  const min = Math.round(ms / 60000)
  if (min < 60) return `${min}m left`
  const h = Math.floor(min / 60)
  return `${h}h ${min % 60}m left`
}

export function BubblesPage() {
  const q = useAsync(listAdminBubbles, [])

  if (isAccessDenied(q.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Bubbles</h1>
          <p className="wb-page-subtitle">
            Active Bubbles: temporary geofences one member draws around another. Read-only.
          </p>
        </div>
        <Button variant="secondary" size="sm" onClick={q.refetch}>
          Refresh
        </Button>
      </div>

      {q.loading && !q.data ? (
        <div className="wb-page-loading">
          <Spinner /> Loading bubbles…
        </div>
      ) : q.error ? (
        <ErrorState title="Couldn’t load bubbles" description={q.error.message} onRetry={q.refetch} />
      ) : !q.data || q.data.length === 0 ? (
        <EmptyState title="No active Bubbles" description="Bubbles that members create will appear here until they expire." />
      ) : (
        <Card padded={false}>
          <ul className="wb-activity-list">
            {q.data.map((b) => (
              <li key={b.id} className="wb-activity-row">
                <Badge tone={b.inside ? 'green' : 'orange'}>{b.inside ? 'Inside' : 'Outside'}</Badge>
                <div className="wb-activity-main">
                  <span className="wb-activity-text">
                    <strong>{b.creator_name}</strong> watches <strong>{b.subject_name}</strong> · {formatRadius(b.radius_m)}
                    {b.notify_reenter ? ' · alerts on return' : ''}
                  </span>
                  <span className="wb-activity-sub">
                    Circle: {b.circle_name} · Members: {b.members.map((m) => m.name).join(', ') || '—'}
                  </span>
                </div>
                <time className="wb-activity-time" dateTime={b.expires_at} title={new Date(b.expires_at).toLocaleString()}>
                  {formatExpiry(b.expires_at)} · created {formatRelativeTime(b.created_at)}
                </time>
              </li>
            ))}
          </ul>
        </Card>
      )}
    </div>
  )
}
