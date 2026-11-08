// Fleet health: per member, whether their phone is actually reporting and, if
// not, why. Everything shown is liveness metadata (last seen, versions, OS
// states, queue size, push status). There are no coordinates here, so the page
// works the same for Private circles.

import React from 'react'
import { getFleetHealth, hideStaleDevices } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import { batteryLabel, bestVersion, deviceFindings, reportNote, memberHealth, summarize, type Health } from '../lib/fleet'
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

function DeviceDetail({ d, now, m }: { d: FleetDevice; now: number; m: FleetMember }) {
  const findings = deviceFindings(d, now, m.in_private_circle ? m.last_activity_at : null)
  const locText = { always: 'Always', while_in_use: 'Only while in use', denied: 'Denied', unknown: 'Not reported' }[d.loc_permission]
  return (
    <div className="wb-fleet-device">
      <div className="wb-fleet-device-head">
        <span className="wb-fleet-device-name">{d.name || (d.platform === 'ios' ? 'iPhone' : 'Android phone')}</span>
        <Badge tone="neutral">{d.platform}</Badge>
        <span className="wb-fleet-sub">
          {d.diag_reported_at ? `Health report ${formatRelativeTime(d.diag_reported_at)}` : reportNote(d)}
        </span>
      </div>
      <dl className="wb-fleet-facts">
        <div><dt>Last seen</dt><dd>{formatRelativeTime(d.last_seen)}</dd></div>
        <div><dt>App version</dt><dd>{d.app_version || 'Not reported'}</dd></div>
        {d.client_version && d.client_version !== d.app_version && (
          <div><dt>Newest version seen for this account</dt><dd>{d.client_version} <span className="wb-fleet-sub">(any phone of theirs, not necessarily this one)</span></dd></div>
        )}
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
            <li key={f.text}>
              <Badge tone={TONE[f.level]} dot>{f.text}</Badge>
              {f.hint && <span className="wb-fleet-hint"> What to do: {f.hint}</span>}
            </li>
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
          <strong>{formatRelativeTime(m.last_activity_at ?? m.last_report_at ?? newest?.last_seen)}</strong>
          <br />last heard
        </span>
        <span className="wb-fleet-cell is-secondary">
          <strong>{newest ? bestVersion(newest) : '—'}</strong>
          <br />{newest?.os_version || 'OS not reported'}
        </span>
        <span className="wb-fleet-chev" aria-hidden="true">›</span>
      </button>
      {open && (
        <div className="wb-fleet-detail">
          {m.in_private_circle && (
            <p className="wb-fleet-private-note">
              Private circle: updates are encrypted, so the server only knows when one arrived. Last update received{' '}
              {formatRelativeTime(m.last_private_update_at ?? m.last_activity_at)}.
            </p>
          )}
          {m.devices.map((d) => (
            <DeviceDetail key={d.id} d={d} now={now} m={m} />
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
  const [staleDays, setStaleDays] = React.useState(7)
  const [stale, setStale] = React.useState<{ count: number; devices: { id: string; user_name: string; platform: string; name: string; last_seen: string | null }[] } | null>(null)
  const [staleMsg, setStaleMsg] = React.useState<{ tone: 'ok' | 'error'; text: string } | null>(null)
  const [staleBusy, setStaleBusy] = React.useState(false)
  const previewStale = async () => {
    setStaleBusy(true)
    setStaleMsg(null)
    try {
      setStale(await hideStaleDevices(staleDays, true))
    } catch (e) {
      setStaleMsg({ tone: 'error', text: e instanceof Error ? e.message : 'Could not check for stale devices.' })
    } finally {
      setStaleBusy(false)
    }
  }
  const confirmStale = async () => {
    setStaleBusy(true)
    try {
      const r = await hideStaleDevices(staleDays, false)
      setStale(null)
      setStaleMsg({ tone: 'ok', text: `Hid ${r.count} stale device row${r.count === 1 ? '' : 's'}. Nothing was deleted; a phone that reports again shows up again.` })
      q.refetch()
    } catch (e) {
      setStaleMsg({ tone: 'error', text: e instanceof Error ? e.message : 'Could not hide stale devices.' })
    } finally {
      setStaleBusy(false)
    }
  }

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

          <Card className="wb-fleet-stale">
            <div className="wb-row">
              <strong>Tidy up old phones</strong>
              <label className="wb-fleet-stale-days">
                not seen for{' '}
                <input className="wb-input" type="number" min={1} max={3650} value={staleDays} aria-label="Days since last seen"
                  onChange={(e) => { setStaleDays(Math.max(1, Number(e.target.value) || 7)); setStale(null) }} />{' '}
                days
              </label>
              <Button variant="secondary" size="sm" loading={staleBusy && !stale} onClick={() => void previewStale()}>Review stale devices</Button>
            </div>
            <p className="wb-help">Hides old duplicate rows from this page. Each person always keeps their newest phone. History is not deleted.</p>
            {stale && (
              <div role="region" aria-label="Stale devices preview">
                {stale.count === 0 ? <p>Nothing to hide.</p> : (
                  <>
                    <p><strong>{stale.count}</strong> device row{stale.count === 1 ? '' : 's'} would be hidden{stale.devices.length < stale.count ? ` (showing ${stale.devices.length})` : ''}:</p>
                    <ul className="wb-fleet-stale-list">
                      {stale.devices.slice(0, 12).map((d) => (
                        <li key={d.id}>{d.user_name} · {d.name || d.platform} · {d.last_seen ? formatRelativeTime(d.last_seen) : 'never seen'}</li>
                      ))}
                    </ul>
                    <Button variant="danger" size="sm" loading={staleBusy} onClick={() => void confirmStale()}>Hide {stale.count} device{stale.count === 1 ? '' : 's'}</Button>{' '}
                  </>
                )}
                <Button variant="ghost" size="sm" onClick={() => setStale(null)}>Cancel</Button>
              </div>
            )}
            {staleMsg && <p className={staleMsg.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{staleMsg.text}</p>}
          </Card>

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
