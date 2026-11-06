// Fleet health: per member, whether their phone is actually reporting and, if
// not, why. Everything shown is liveness metadata (last seen, versions, OS
// states, queue size, push status). There are no coordinates here, so the page
// works the same for Private circles.

import React from 'react'
import { getFleetHealth } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import { batteryLabel, deviceFindings, memberHealth, summarize, type Health } from '../lib/fleet'
import type { FleetDevice, FleetMember } from '../lib/types'
import './pages.css'
import './FleetPage.css'

type Filter = 'all' | 'bad' | 'warn' | 'ok'

const TONE = { ok: 'green', warn: 'orange', bad: 'red', unknown: 'grey' } as const
const LABEL: Record<Health, string> = { ok: 'Healthy', warn: 'Needs a look', bad: 'Not reporting', unknown: 'No phone' }

function pushText(d: FleetDevice): string {
  if (!d.push_registered) return 'Not registered'
  const ok = d.last_push_ok_at ? formatRelativeTime(d.last_push_ok_at) : null
  const failed = d.last_push_fail_at && (!d.last_push_ok_at || d.last_push_fail_at > d.last_push_ok_at)
  if (failed) return `Last attempt failed ${formatRelativeTime(d.last_push_fail_at)}`
  return ok ? `Delivered ${ok}` : `Registered (${d.push_transport || 'provider'}), none sent yet`
}

function DeviceDetail({ d, now }: { d: FleetDevice; now: number }) {
  const findings = deviceFindings(d, now)
  const locText = { always: 'Always', while_in_use: 'Only while in use', denied: 'Denied', unknown: 'Not reported' }[d.loc_permission]
  return (
    <div className="wb-fleet-device">
      <div className="wb-fleet-device-head">
        <span className="wb-fleet-device-name">{d.name || (d.platform === 'ios' ? 'iPhone' : 'Android phone')}</span>
        <Badge tone="neutral">{d.platform}</Badge>
        <span className="wb-fleet-sub">
          {d.diag_reported_at ? `Self-report ${formatRelativeTime(d.diag_reported_at)}` : 'No self-report yet (app older than this feature)'}
        </span>
      </div>
      <dl className="wb-fleet-facts">
        <div><dt>Last seen</dt><dd>{formatRelativeTime(d.last_seen)}</dd></div>
        <div><dt>App version</dt><dd>{d.app_version || 'Unknown'}</dd></div>
        <div><dt>OS</dt><dd>{d.os_version || 'Not reported'}</dd></div>
        <div><dt>Battery optimisation</dt><dd>{batteryLabel(d.battery_opt)}</dd></div>
        <div><dt>Location permission</dt><dd>{locText}</dd></div>
        <div><dt>Notifications</dt><dd>{d.notif_permission === 'unknown' ? 'Not reported' : d.notif_permission === 'granted' ? 'Allowed' : 'Blocked'}</dd></div>
        <div><dt>Waiting to upload</dt><dd>{d.outbox_pending == null ? 'Not reported' : `${d.outbox_pending} point${d.outbox_pending === 1 ? '' : 's'}`}</dd></div>
        <div><dt>Background service</dt><dd>{d.bg_service == null ? 'Not reported' : d.bg_service ? 'Running' : 'Stopped'}</dd></div>
        <div><dt>Push</dt><dd>{pushText(d)}</dd></div>
      </dl>
      {findings.length > 0 && (
        <ul className="wb-fleet-findings" aria-label="Findings">
          {findings.map((f) => (
            <li key={f.text}><Badge tone={TONE[f.level]} dot>{f.text}</Badge></li>
          ))}
        </ul>
      )}
    </div>
  )
}

function MemberRow({ m, now, open, onToggle }: { m: FleetMember; now: number; open: boolean; onToggle: () => void }) {
  const health = memberHealth(m, now)
  const newest = m.devices[0]
  return (
    <li className={`wb-fleet-row${open ? ' is-open' : ''}`}>
      <button type="button" className="wb-fleet-summary" aria-expanded={open} onClick={onToggle}>
        <span className="wb-fleet-who">
          <span className="wb-fleet-name">{m.name || m.email}</span>
          <span className="wb-fleet-sub">{m.email}{m.in_private_circle ? ' · Private circle' : ''}</span>
        </span>
        <Badge tone={TONE[health]} dot>{LABEL[health]}</Badge>
        <span className="wb-fleet-cell">
          <strong>{formatRelativeTime(m.last_report_at ?? newest?.last_seen)}</strong>
          <br />last heard
        </span>
        <span className="wb-fleet-cell is-secondary">
          <strong>{newest?.app_version || '—'}</strong>
          <br />{newest?.os_version || 'OS not reported'}
        </span>
        <span className="wb-fleet-chev" aria-hidden="true">›</span>
      </button>
      {open && (
        <div className="wb-fleet-detail">
          {m.devices.map((d) => (
            <DeviceDetail key={d.id} d={d} now={now} />
          ))}
        </div>
      )}
    </li>
  )
}

export function FleetPage() {
  const q = useAsync(getFleetHealth, [])
  const [filter, setFilter] = React.useState<Filter>('all')
  const [openId, setOpenId] = React.useState<string | null>(null)

  if (isAccessDenied(q.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  // The server clock decides "now", so a wrong admin-browser clock cannot skew the verdicts.
  const now = q.data ? new Date(q.data.server_time).getTime() : Date.now()
  const members = q.data?.members ?? []
  const s = summarize(members, now)
  const shown = members.filter((m) => filter === 'all' || memberHealth(m, now) === filter)
  const FILTERS: { key: Filter; label: string }[] = [
    { key: 'all', label: `All (${s.total})` },
    { key: 'bad', label: `Not reporting (${s.bad})` },
    { key: 'warn', label: `Needs a look (${s.warn})` },
    { key: 'ok', label: `Healthy (${s.ok})` },
  ]

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Fleet health</h1>
          <p className="wb-page-subtitle">Is each phone actually reporting, and if not, why. Timestamps and device states only, never locations.</p>
        </div>
        <Button variant="secondary" size="sm" onClick={q.refetch}>Refresh</Button>
      </div>

      {q.loading && !q.data ? (
        <div className="wb-page-loading"><Spinner /> Loading fleet…</div>
      ) : q.error ? (
        <ErrorState title="Couldn’t load fleet health" description={q.error.message} onRetry={q.refetch} />
      ) : members.length === 0 ? (
        <EmptyState title="No phones yet" description="Members appear here once they sign in on a phone." />
      ) : (
        <>
          <div className="wb-fleet-stats">
            <Card className="wb-fleet-stat"><span className="wb-fleet-stat-num">{s.total}</span><span className="wb-fleet-stat-label">Members</span></Card>
            <Card className="wb-fleet-stat is-ok"><span className="wb-fleet-stat-num">{s.ok}</span><span className="wb-fleet-stat-label">Healthy</span></Card>
            <Card className="wb-fleet-stat is-warn"><span className="wb-fleet-stat-num">{s.warn}</span><span className="wb-fleet-stat-label">Need a look</span></Card>
            <Card className="wb-fleet-stat is-bad"><span className="wb-fleet-stat-num">{s.bad}</span><span className="wb-fleet-stat-label">Not reporting</span></Card>
            <Card className="wb-fleet-stat"><span className="wb-fleet-stat-num">{s.noPush}</span><span className="wb-fleet-stat-label">No push channel</span></Card>
            <Card className="wb-fleet-stat"><span className="wb-fleet-stat-num">{s.pendingPoints}</span><span className="wb-fleet-stat-label">Points waiting</span></Card>
          </div>

          <div className="wb-fleet-filters" role="group" aria-label="Filter by health">
            {FILTERS.map((f) => (
              <button key={f.key} type="button" className={`wb-fleet-chip${filter === f.key ? ' is-on' : ''}`} aria-pressed={filter === f.key} onClick={() => setFilter(f.key)}>
                {f.label}
              </button>
            ))}
          </div>

          {shown.length === 0 ? (
            <EmptyState title="Nothing in this view" description="No members match the selected health filter." />
          ) : (
            <Card padded={false}>
              <ul className="wb-fleet-list">
                {shown.map((m) => (
                  <MemberRow key={m.user_id} m={m} now={now} open={openId === m.user_id} onToggle={() => setOpenId(openId === m.user_id ? null : m.user_id)} />
                ))}
              </ul>
            </Card>
          )}
          <p className="wb-fleet-note">
            A member counts as healthy if at least one of their phones is. Battery, permission and queue values are reported
            by the app itself, so a phone running an older build shows &ldquo;Not reported&rdquo; for them.
          </p>
        </>
      )}
    </div>
  )
}
