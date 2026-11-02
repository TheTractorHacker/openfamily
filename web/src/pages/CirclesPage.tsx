// Circles & invites — every circle (with temporary-circle expiry, extend and
// end-now controls) and every invite code (with revoke). Platform admins only.

import React from 'react'
import {
  ApiError,
  listAdminCircles,
  listInvites,
  revokeAdminInvite,
  updateAdminCircle,
} from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Mono, Spinner } from '../components/primitives'
import { formatTimeLeft } from '../lib/format'
import type { AdminCircle, AdminInvite } from '../lib/types'
import './pages.css'
import './AuditPage.css'

function whenText(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

const TONE = { permanent: 'purple', active: 'green', expired: 'grey', ended: 'orange' } as const

function errorText(e: unknown): string {
  return e instanceof ApiError || e instanceof Error ? e.message : 'Request failed'
}

export function CirclesPage() {
  const circlesQ = useAsync(listAdminCircles, [])
  const invitesQ = useAsync(listInvites, [])
  const [busy, setBusy] = React.useState<string | null>(null)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)
  const [onlyTemp, setOnlyTemp] = React.useState(false)

  if (isAccessDenied(circlesQ.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  if (circlesQ.loading && !circlesQ.data) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading circles…
        </div>
      </div>
    )
  }
  if (circlesQ.error) {
    return (
      <div className="wb-page">
        <ErrorState title="Couldn’t load circles" description={circlesQ.error.message} onRetry={circlesQ.refetch} />
      </div>
    )
  }

  const circles: AdminCircle[] = circlesQ.data ?? []
  const shown = onlyTemp ? circles.filter((c) => c.status !== 'permanent') : circles
  const invites: AdminInvite[] = invitesQ.data ?? []

  const change = async (c: AdminCircle, body: { end: true } | { extend_hours: number }, ok: string) => {
    setBusy(c.id)
    setMessage(null)
    try {
      await updateAdminCircle(c.id, body)
      setMessage({ tone: 'success', text: ok })
      circlesQ.refetch()
    } catch (e) {
      setMessage({ tone: 'error', text: errorText(e) })
    } finally {
      setBusy(null)
    }
  }

  const endNow = (c: AdminCircle) => {
    if (!window.confirm(`End “${c.name}” now? Its members stop sharing with it immediately.`)) return
    void change(c, { end: true }, 'Circle ended.')
  }

  const revokeInvite = async (inv: AdminInvite) => {
    if (!window.confirm(`Revoke invite ${inv.code}?`)) return
    setBusy(inv.id)
    setMessage(null)
    try {
      await revokeAdminInvite(inv.id)
      setMessage({ tone: 'success', text: 'Invite revoked.' })
      invitesQ.refetch()
    } catch (e) {
      setMessage({ tone: 'error', text: errorText(e) })
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="wb-page">
      <section className="wb-audit-section" aria-labelledby="circles-h">
        <div className="wb-audit-sectionhead">
          <div style={{ marginRight: 'auto' }}>
            <h1 id="circles-h" className="wb-page-title">
              Circles
            </h1>
            <p className="wb-page-subtitle">
              Temporary circles stop sharing at their expiry and are deleted a week later. Extend or end them here.
            </p>
          </div>
          <label className="wb-field" style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
            <input type="checkbox" checked={onlyTemp} onChange={(e) => setOnlyTemp(e.target.checked)} />
            <span className="wb-label">Temporary only</span>
          </label>
          <Button variant="secondary" size="sm" onClick={() => circlesQ.refetch()}>
            Refresh
          </Button>
        </div>
        {message && (
          <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">
            {message.text}
          </p>
        )}
        {shown.length === 0 ? (
          <EmptyState title="No circles" description="Nothing matches this filter." />
        ) : (
          <Card padded={false}>
            <div className="wb-audit-tablewrap">
              <table className="wb-table">
                <thead>
                  <tr>
                    <th>Circle</th>
                    <th>Members</th>
                    <th>Created by</th>
                    <th>Status</th>
                    <th>Expires</th>
                    <th aria-label="Actions" />
                  </tr>
                </thead>
                <tbody>
                  {shown.map((c) => {
                    const temp = c.expires_at !== null && !c.family_backed
                    const canExtend = temp && c.status !== 'ended'
                    const canEnd = temp && c.status === 'active'
                    return (
                      <tr key={c.id}>
                        <td>
                          <div className="wb-audit-user">
                            {c.icon ? `${c.icon} ` : ''}
                            {c.name}
                          </div>
                          {c.family_backed && <div className="wb-audit-sub">Family circle</div>}
                        </td>
                        <td>{c.member_count}</td>
                        <td>{c.creator_name ?? '—'}</td>
                        <td>
                          <Badge tone={TONE[c.status]}>{c.status}</Badge>
                        </td>
                        <td title={whenText(c.ended_at ?? c.expires_at)}>
                          {c.status === 'ended'
                            ? `ended ${whenText(c.ended_at)}`
                            : c.expires_at
                              ? `${formatTimeLeft(c.expires_at)} · ${whenText(c.expires_at)}`
                              : '—'}
                        </td>
                        <td>
                          <div className="wb-row">
                            {canExtend && (
                              <>
                                <Button
                                  variant="secondary"
                                  size="sm"
                                  disabled={busy !== null}
                                  loading={busy === c.id}
                                  onClick={() => void change(c, { extend_hours: 24 }, 'Extended by 24 hours.')}
                                >
                                  +24h
                                </Button>
                                <Button
                                  variant="secondary"
                                  size="sm"
                                  disabled={busy !== null}
                                  onClick={() => void change(c, { extend_hours: 168 }, 'Extended by 7 days.')}
                                >
                                  +7d
                                </Button>
                              </>
                            )}
                            {canEnd && (
                              <Button variant="danger" size="sm" disabled={busy !== null} onClick={() => endNow(c)}>
                                End now
                              </Button>
                            )}
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </Card>
        )}
      </section>

      <section className="wb-audit-section" aria-labelledby="invites-h">
        <div className="wb-audit-sectionhead">
          <h2 id="invites-h" className="wb-audit-h2">
            Invite codes
          </h2>
          <Button variant="secondary" size="sm" onClick={() => invitesQ.refetch()}>
            Refresh
          </Button>
        </div>
        {invitesQ.loading && !invitesQ.data ? (
          <div className="wb-page-loading">
            <Spinner /> Loading invites…
          </div>
        ) : invitesQ.error ? (
          <ErrorState title="Couldn’t load invites" description={invitesQ.error.message} onRetry={invitesQ.refetch} />
        ) : invites.length === 0 ? (
          <EmptyState title="No invite codes" description="Codes created in the app or on the Families page show here." />
        ) : (
          <Card padded={false}>
            <div className="wb-audit-tablewrap">
              <table className="wb-table">
                <thead>
                  <tr>
                    <th>Code</th>
                    <th>Joins</th>
                    <th>Role</th>
                    <th>Uses</th>
                    <th>Expires</th>
                    <th aria-label="Actions" />
                  </tr>
                </thead>
                <tbody>
                  {invites.map((inv) => {
                    const expired = inv.expires_at !== null && new Date(inv.expires_at).getTime() <= Date.now()
                    const used = inv.max_uses > 0 && inv.uses >= inv.max_uses
                    return (
                      <tr key={inv.id}>
                        <td>
                          <Mono>{inv.code}</Mono>
                        </td>
                        <td>
                          <div className="wb-audit-user">{inv.circle_name || inv.family_name || '—'}</div>
                          {inv.circle_name && inv.family_name && inv.circle_name !== inv.family_name && (
                            <div className="wb-audit-sub">{inv.family_name}</div>
                          )}
                        </td>
                        <td>{inv.role}</td>
                        <td>
                          {inv.uses}
                          {inv.max_uses > 0 ? ` / ${inv.max_uses}` : ''}
                        </td>
                        <td>
                          {inv.expires_at ? (
                            expired ? (
                              <Badge tone="grey">expired</Badge>
                            ) : (
                              whenText(inv.expires_at)
                            )
                          ) : (
                            'never'
                          )}
                          {used && !expired && (
                            <>
                              {' '}
                              <Badge tone="grey">used up</Badge>
                            </>
                          )}
                        </td>
                        <td>
                          <Button
                            variant="danger"
                            size="sm"
                            loading={busy === inv.id}
                            disabled={busy !== null}
                            onClick={() => void revokeInvite(inv)}
                          >
                            Revoke
                          </Button>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </Card>
        )}
      </section>
    </div>
  )
}
