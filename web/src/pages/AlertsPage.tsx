// Alerts & SOS — recent check-ins, help requests and SOS alerts with who was
// notified and who acknowledged. Coordinates and notes are never shown.

import React from 'react'
import { listAdminAlerts } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import type { AdminAlert, AdminAlertDelivery } from '../lib/types'
import './pages.css'
import './ActivityPage.css'

const TYPE_LABEL: Record<string, string> = { sos: 'SOS', help: 'Help', check_in: 'Check-in' }
const STATE_TONE = {
  queued: 'grey',
  sent: 'neutral',
  delivered: 'green',
  acknowledged: 'purple',
  failed: 'red',
} as const

function typeLabel(t: string): string {
  return TYPE_LABEL[t] ?? t.replace(/_/g, ' ')
}

function DeliverySummary({ d }: { d: AdminAlertDelivery[] }) {
  if (d.length === 0) return <span className="wb-help">No recipients recorded</span>
  return (
    <ul style={{ listStyle: 'none', margin: 0, padding: 0, display: 'flex', flexWrap: 'wrap', gap: 6 }}>
      {d.map((x, i) => (
        <li key={`${x.recipient}-${x.channel}-${i}`}>
          <Badge
            tone={STATE_TONE[x.state] ?? 'grey'}
            title={
              x.acknowledged_at
                ? `Acknowledged ${new Date(x.acknowledged_at).toLocaleString()}`
                : x.error
                  ? `Failed: ${x.error}`
                  : undefined
            }
          >
            {x.recipient || 'Unknown'} · {x.channel} · {x.state}
          </Badge>
        </li>
      ))}
    </ul>
  )
}

export function AlertsPage() {
  const [status, setStatus] = React.useState('')
  const [type, setType] = React.useState('')
  const q = useAsync(() => listAdminAlerts({ status, type, limit: 50 }), [status, type])
  const [extra, setExtra] = React.useState<AdminAlert[]>([])
  const [next, setNext] = React.useState('')
  const [more, setMore] = React.useState(false)

  React.useEffect(() => {
    setExtra([])
    setNext(q.data?.next_before ?? '')
  }, [q.data])

  if (isAccessDenied(q.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  const loadMore = async () => {
    setMore(true)
    try {
      const page = await listAdminAlerts({ status, type, before: next, limit: 50 })
      setExtra((cur) => [...cur, ...page.alerts])
      setNext(page.next_before)
    } finally {
      setMore(false)
    }
  }

  const alerts = [...(q.data?.alerts ?? []), ...extra]

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Alerts &amp; SOS</h1>
          <p className="wb-page-subtitle">
            Recent alerts, who was notified and who acknowledged. Locations and notes are never shown here.
          </p>
        </div>
        <Button variant="secondary" size="sm" onClick={q.refetch}>
          Refresh
        </Button>
      </div>

      <div className="wb-activity-filters">
        <label className="wb-field" htmlFor="alerts-status">
          <span className="wb-label">Status</span>
          <select id="alerts-status" className="wb-input" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All</option>
            <option value="active">Active</option>
            <option value="resolved">Resolved</option>
          </select>
        </label>
        <label className="wb-field" htmlFor="alerts-type">
          <span className="wb-label">Type</span>
          <select id="alerts-type" className="wb-input" value={type} onChange={(e) => setType(e.target.value)}>
            <option value="">All</option>
            <option value="sos">SOS</option>
            <option value="help">Help</option>
            <option value="check_in">Check-in</option>
          </select>
        </label>
      </div>

      {q.loading && !q.data ? (
        <div className="wb-page-loading">
          <Spinner /> Loading alerts…
        </div>
      ) : q.error ? (
        <ErrorState title="Couldn’t load alerts" description={q.error.message} onRetry={q.refetch} />
      ) : alerts.length === 0 ? (
        <EmptyState title="No alerts" description="Check-ins, help requests and SOS alerts appear here." />
      ) : (
        <>
          <Card padded={false}>
            <ul className="wb-activity-list">
              {alerts.map((a) => (
                <li key={a.id} className="wb-activity-row" style={{ alignItems: 'flex-start' }}>
                  <Badge tone={a.type === 'sos' ? 'red' : a.type === 'help' ? 'orange' : 'neutral'}>
                    {typeLabel(a.type)}
                  </Badge>
                  <div className="wb-activity-main">
                    <span className="wb-activity-text">
                      {a.sender_name}
                      {a.family_name ? ` · ${a.family_name}` : ''}{' '}
                      <Badge tone={a.status === 'active' ? 'orange' : 'grey'}>{a.status}</Badge>
                      {a.has_location && <span className="wb-activity-sub"> · location attached (hidden)</span>}
                    </span>
                    <DeliverySummary d={a.deliveries} />
                  </div>
                  <span className="wb-activity-time" title={new Date(a.created_at).toLocaleString()}>
                    {formatRelativeTime(a.created_at)}
                  </span>
                </li>
              ))}
            </ul>
          </Card>
          {next && (
            <div className="wb-activity-more">
              <Button variant="secondary" loading={more} onClick={() => void loadMore()}>
                Load more
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  )
}
