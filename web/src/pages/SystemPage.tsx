// System health — migration version, database size, last backup, release
// version and recent server warnings/errors. Read-only; no secrets.

import React from 'react'
import { getAdminHealth } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { Alert, CopyCommand, KeyValueList, PageHeader, Section } from '../components/patterns'
import { formatBytes, formatRelativeTime } from '../lib/format'
import { BackupsCard } from './BackupsCard'
import { destinationLabel, splitWarning } from '../lib/backups'
import './pages.css'
import './SystemPage.css'

const BACKUP_TONE = { ok: 'green', stale: 'orange', missing: 'red' } as const
const BACKUP_TEXT = { ok: 'Recent', stale: 'Overdue', missing: 'No backup recorded' } as const

export function SystemPage() {
  const q = useAsync(getAdminHealth, [])
  const [updatedAt, setUpdatedAt] = React.useState<Date | null>(null)
  React.useEffect(() => {
    if (q.data) setUpdatedAt(new Date())
  }, [q.data])

  if (isAccessDenied(q.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  const refreshing = q.loading && !!q.data
  const h = q.data

  return (
    <div className="wb-page">
      <PageHeader
        title="System health"
        subtitle="The server's state at a glance."
        actions={
          <>
            {updatedAt && <span className="wb-sys-updated">Updated {updatedAt.toLocaleTimeString()}</span>}
            <Button variant="secondary" size="sm" onClick={q.refetch} loading={refreshing} aria-label="Refresh system health">
              {refreshing ? 'Refreshing' : 'Refresh'}
            </Button>
          </>
        }
      />

      {q.loading && !h ? (
        <div className="wb-page-loading">
          <Spinner /> Loading…
        </div>
      ) : q.error ? (
        <ErrorState title="Couldn’t load system health" description={q.error.message} onRetry={q.refetch} />
      ) : h ? (
        <>
          {h.warnings.length > 0 && (
            <div className="wb-alert-stack">
              {h.warnings.map((w) => {
                const { message, command } = splitWarning(w)
                return (
                  <Alert
                    key={w}
                    tone="danger"
                    title="Needs attention"
                    action={command ? <CopyCommand command={command} /> : undefined}
                  >
                    {message}
                  </Alert>
                )
              })}
            </div>
          )}

          <Section title="Server">
            <Card>
              <KeyValueList
                label="Server facts"
                items={[
                  { label: 'Release', value: h.release_version || 'dev', mono: true },
                  {
                    label: 'Database migration',
                    value: (
                      <>
                        <span>{String(h.migration.version)}</span>
                        {h.migration.dirty && <Badge tone="red">not clean</Badge>}
                      </>
                    ),
                    mono: true,
                  },
                  { label: 'Database size', value: formatBytes(h.database_bytes), mono: true },
                  {
                    label: 'Last backup',
                    value: (
                      <>
                        <Badge tone={BACKUP_TONE[h.backup.status]} dot>
                          {BACKUP_TEXT[h.backup.status]}
                        </Badge>
                        {h.backup.last_at && (
                          <span className="wb-kv-note" title={new Date(h.backup.last_at).toLocaleString()}>
                            {formatRelativeTime(h.backup.last_at)}
                            {h.backup.destination ? ` · ${destinationLabel(h.backup.destination)}` : ''}
                            {h.backup.size_bytes != null ? ` · ${formatBytes(h.backup.size_bytes)}` : ''}
                          </span>
                        )}
                      </>
                    ),
                  },
                ]}
              />
            </Card>
          </Section>

          <BackupsCard onChanged={q.refetch} />

          <Section title="Recent warnings and errors" description="Since the server last started.">
            {h.recent_errors.length === 0 ? (
              <EmptyState title="Nothing to report" description="No warnings or errors since the server started." />
            ) : (
              <Card padded={false}>
                <ul className="wb-sys-log">
                  {h.recent_errors.map((e, i) => (
                    <li key={`${e.time}-${i}`} className="wb-sys-log-row">
                      <Badge tone={e.level === 'ERROR' ? 'red' : 'orange'}>{e.level.toLowerCase()}</Badge>
                      <span className="wb-sys-log-msg">{e.message}</span>
                      <span className="wb-sys-log-time" title={new Date(e.time).toLocaleString()}>
                        {formatRelativeTime(e.time)}
                      </span>
                    </li>
                  ))}
                </ul>
              </Card>
            )}
          </Section>
        </>
      ) : null}
    </div>
  )
}
