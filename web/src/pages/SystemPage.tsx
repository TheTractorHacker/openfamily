// System health — migration version, database size, last backup, release
// version and recent server warnings/errors. Read-only; no secrets.

import { getAdminHealth } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Mono, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import './pages.css'
import './ActivityPage.css'

export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '—'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let v = n
  let i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i += 1
  }
  return `${i === 0 ? v : v.toFixed(1)} ${units[i]}`
}

const BACKUP_TONE = { ok: 'green', stale: 'orange', missing: 'red' } as const
const BACKUP_TEXT = { ok: 'Recent', stale: 'Overdue', missing: 'No backup recorded' } as const

export function SystemPage() {
  const q = useAsync(getAdminHealth, [])

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
          <h1 className="wb-page-title">System health</h1>
          <p className="wb-page-subtitle">The server&apos;s state at a glance. Read-only.</p>
        </div>
        <Button variant="secondary" size="sm" onClick={q.refetch}>
          Refresh
        </Button>
      </div>

      {q.loading && !q.data ? (
        <div className="wb-page-loading">
          <Spinner /> Loading…
        </div>
      ) : q.error ? (
        <ErrorState title="Couldn’t load system health" description={q.error.message} onRetry={q.refetch} />
      ) : q.data ? (
        <>
          {q.data.warnings.length > 0 && (
            <Card>
              <ul role="alert" style={{ margin: 0, paddingLeft: 20 }}>
                {q.data.warnings.map((w) => (
                  <li key={w} className="wb-error-text">
                    {w}
                  </li>
                ))}
              </ul>
            </Card>
          )}
          <Card>
            <dl style={{ margin: 0, display: 'grid', gap: 12 }} aria-label="Server facts">
              <div className="wb-row">
                <dt className="wb-label" style={{ minWidth: 180 }}>Release</dt>
                <dd style={{ margin: 0 }}>
                  <Mono>{q.data.release_version || 'dev'}</Mono>
                </dd>
              </div>
              <div className="wb-row">
                <dt className="wb-label" style={{ minWidth: 180 }}>Database migration</dt>
                <dd style={{ margin: 0 }}>
                  <Mono>{String(q.data.migration.version)}</Mono>{' '}
                  {q.data.migration.dirty && <Badge tone="red">not clean</Badge>}
                </dd>
              </div>
              <div className="wb-row">
                <dt className="wb-label" style={{ minWidth: 180 }}>Database size</dt>
                <dd style={{ margin: 0 }}>{formatBytes(q.data.database_bytes)}</dd>
              </div>
              <div className="wb-row">
                <dt className="wb-label" style={{ minWidth: 180 }}>Last backup</dt>
                <dd style={{ margin: 0 }}>
                  <Badge tone={BACKUP_TONE[q.data.backup.status]}>{BACKUP_TEXT[q.data.backup.status]}</Badge>{' '}
                  {q.data.backup.last_at && (
                    <span title={new Date(q.data.backup.last_at).toLocaleString()}>
                      {formatRelativeTime(q.data.backup.last_at)}
                      {q.data.backup.size_bytes != null ? ` · ${formatBytes(q.data.backup.size_bytes)}` : ''}
                    </span>
                  )}
                </dd>
              </div>
            </dl>
          </Card>

          <h2 className="wb-audit-h2">Recent warnings and errors</h2>
          {q.data.recent_errors.length === 0 ? (
            <EmptyState title="Nothing to report" description="No warnings or errors since the server started." />
          ) : (
            <Card padded={false}>
              <ul className="wb-activity-list">
                {q.data.recent_errors.map((e, i) => (
                  <li key={`${e.time}-${i}`} className="wb-activity-row">
                    <Badge tone={e.level === 'ERROR' ? 'red' : 'orange'}>{e.level.toLowerCase()}</Badge>
                    <div className="wb-activity-main">
                      <span className="wb-activity-text">{e.message}</span>
                    </div>
                    <span className="wb-activity-time" title={new Date(e.time).toLocaleString()}>
                      {formatRelativeTime(e.time)}
                    </span>
                  </li>
                ))}
              </ul>
            </Card>
          )}
        </>
      ) : null}
    </div>
  )
}
