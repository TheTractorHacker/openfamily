// Active sessions for the Audit page: grouped by person and device, with
// bulk clean-up (revoke all except this session / revoke inactive) that always
// previews the count first. Platform admin only; the server audits every action.

import React from 'react'
import { bulkRevokeSessions, listAdminSessions, listUsers, revokeAdminSession } from '../lib/api'
import { useAsync } from '../lib/useAsync'
import { Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import type { AdminSession } from '../lib/types'
import './AuditPage.css'

/** A short device label from a raw User-Agent string. */
export function deviceLabel(ua: string): string {
  if (!ua) return 'Unknown device'
  if (/Orbitly/i.test(ua)) return ua.length > 60 ? `${ua.slice(0, 57)}…` : ua
  const browser = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox'
    : /Safari\//.test(ua) ? 'Safari' : /okhttp|Dart/i.test(ua) ? 'Mobile app' : 'Browser'
  const os = /Android/.test(ua) ? 'Android' : /iPhone|iPad|iOS/.test(ua) ? 'iOS' : /Windows/.test(ua) ? 'Windows'
    : /Mac OS X/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : ''
  return os ? `${browser} on ${os}` : browser
}

function whenText(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

type Pending =
  | { kind: 'except'; count: number }
  | { kind: 'inactive'; count: number; days: number }
  | null

const PAGE = 15

export function SessionsSection({ onChanged }: { onChanged: () => void }) {
  const [userId, setUserId] = React.useState('')
  const usersQ = useAsync(listUsers, [])
  const q = useAsync(() => listAdminSessions(userId || undefined), [userId])
  const [msg, setMsg] = React.useState<{ tone: 'ok' | 'error'; text: string } | null>(null)
  const [busy, setBusy] = React.useState<string | null>(null)
  const [days, setDays] = React.useState(7)
  const [pending, setPending] = React.useState<Pending>(null)
  const [openUsers, setOpenUsers] = React.useState<Record<string, boolean>>({})
  const [shown, setShown] = React.useState<Record<string, number>>({})

  const sessions = q.data ?? []
  const groups = React.useMemo(() => {
    const m = new Map<string, { id: string; name: string; email: string; items: AdminSession[] }>()
    for (const s of sessions) {
      const g = m.get(s.user_id) ?? { id: s.user_id, name: s.user_name, email: s.user_email, items: [] }
      g.items.push(s)
      m.set(s.user_id, g)
    }
    return [...m.values()].sort((a, b) => b.items.length - a.items.length)
  }, [sessions])
  const hasCurrent = sessions.some((s) => s.current)

  const done = (text: string, tone: 'ok' | 'error' = 'ok') => setMsg({ tone, text })
  const refresh = () => {
    q.refetch()
    onChanged()
  }

  const preview = async (kind: 'except' | 'inactive') => {
    setBusy(kind)
    setMsg(null)
    try {
      const r = await bulkRevokeSessions(
        kind === 'except'
          ? { mode: 'all_except_current', user_id: userId || undefined, dry_run: true }
          : { mode: 'inactive', days, user_id: userId || undefined, dry_run: true },
      )
      setPending(kind === 'except' ? { kind, count: r.count } : { kind, count: r.count, days })
    } catch (e) {
      done(e instanceof Error ? e.message : 'Could not count sessions.', 'error')
    } finally {
      setBusy(null)
    }
  }
  const confirm = async () => {
    if (!pending) return
    setBusy('confirm')
    try {
      const r = await bulkRevokeSessions(
        pending.kind === 'except'
          ? { mode: 'all_except_current', user_id: userId || undefined }
          : { mode: 'inactive', days: pending.days, user_id: userId || undefined },
      )
      setPending(null)
      done(`Signed out ${r.revoked ?? r.count} session${(r.revoked ?? r.count) === 1 ? '' : 's'}. Your own session was kept.`)
      refresh()
    } catch (e) {
      done(e instanceof Error ? e.message : 'Could not revoke sessions.', 'error')
    } finally {
      setBusy(null)
    }
  }
  const revokeOne = async (s: AdminSession) => {
    if (s.current) return
    if (!window.confirm(`Sign ${s.user_name} out of this device? Their refresh token stops working now.`)) return
    setBusy(s.id)
    setMsg(null)
    try {
      await revokeAdminSession(s.id)
      done('Session revoked.')
      refresh()
    } catch (e) {
      done(e instanceof Error ? e.message : 'Could not revoke the session.', 'error')
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="wb-audit-section" aria-labelledby="sessions-h">
      <div className="wb-audit-sectionhead">
        <h2 id="sessions-h" className="wb-audit-h2">Active sessions <span className="wb-audit-sub">({sessions.length})</span></h2>
        <label className="wb-field" htmlFor="sessions-user">
          <span className="wb-label">User</span>
          <select id="sessions-user" className="wb-select" value={userId} onChange={(e) => { setUserId(e.target.value); setPending(null) }}>
            <option value="">Everyone</option>
            {(usersQ.data ?? []).map((u) => (
              <option key={u.id} value={u.id}>{u.name} ({u.email})</option>
            ))}
          </select>
        </label>
        <Button variant="secondary" size="sm" onClick={() => q.refetch()}>Refresh</Button>
      </div>

      <Card className="wb-sess-bulk">
        <div className="wb-sess-bulk-row">
          <Button variant="secondary" size="sm" loading={busy === 'except'} disabled={!hasCurrent || busy !== null} onClick={() => void preview('except')}
            title={hasCurrent ? undefined : 'Your own session is not in this list, so it cannot be protected. Clear the user filter.'}>
            Revoke all except this session
          </Button>
          <span className="wb-sess-or">or</span>
          <label className="wb-sess-days">
            inactive for{' '}
            <input className="wb-input" type="number" min={1} max={3650} value={days} aria-label="Days of inactivity"
              onChange={(e) => { setDays(Math.max(1, Number(e.target.value) || 1)); setPending(null) }} /> days
          </label>
          <Button variant="secondary" size="sm" loading={busy === 'inactive'} disabled={busy !== null} onClick={() => void preview('inactive')}>
            Revoke inactive sessions
          </Button>
        </div>
        {pending && (
          <div className="wb-sess-confirm" role="alertdialog" aria-label="Confirm bulk revoke">
            {pending.count === 0 ? (
              <span>No sessions match.</span>
            ) : (
              <span>
                This will sign out <strong>{pending.count}</strong> session{pending.count === 1 ? '' : 's'}
                {pending.kind === 'inactive' ? ` with no activity for ${pending.days} days` : ' (everything except the one you are using now)'}
                {userId ? ' for the selected user' : ''}. People are asked to sign in again.
              </span>
            )}
            {pending.count > 0 && (
              <Button variant="danger" size="sm" loading={busy === 'confirm'} onClick={() => void confirm()}>Sign out {pending.count}</Button>
            )}
            <Button variant="ghost" size="sm" onClick={() => setPending(null)}>Cancel</Button>
          </div>
        )}
      </Card>

      {msg && <p className={msg.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{msg.text}</p>}

      {q.loading && !q.data ? (
        <div className="wb-page-loading"><Spinner /> Loading sessions…</div>
      ) : q.error ? (
        <ErrorState title="Couldn’t load sessions" description={q.error.message} onRetry={q.refetch} />
      ) : sessions.length === 0 ? (
        <EmptyState title="No active sessions" description="Nobody is signed in right now." />
      ) : (
        <div className="wb-sess-groups">
          {groups.map((g) => {
            const open = openUsers[g.id] ?? (groups.length <= 3 || g.items.some((s) => s.current))
            const n = shown[g.id] ?? PAGE
            const newest = g.items.reduce((a, s) => (s.last_used_at > a ? s.last_used_at : a), '')
            return (
              <Card key={g.id} padded={false} className="wb-sess-group">
                <button type="button" className="wb-sess-grouphead" aria-expanded={open}
                  onClick={() => setOpenUsers({ ...openUsers, [g.id]: !open })}>
                  <span className="wb-sess-who">
                    <span className="wb-audit-user">{g.name}</span>
                    <span className="wb-audit-sub">{g.email}</span>
                  </span>
                  <Badge tone={g.items.length > 5 ? 'orange' : 'neutral'}>{g.items.length} session{g.items.length === 1 ? '' : 's'}</Badge>
                  <span className="wb-audit-sub">last active {formatRelativeTime(newest)}</span>
                  <span className="wb-fleet-chev" aria-hidden="true">{open ? '⌄' : '›'}</span>
                </button>
                {open && (
                  <div className="wb-audit-tablewrap">
                    <table className="wb-table wb-sess-table">
                      <thead>
                        <tr><th>Device</th><th>Last active</th><th>Signed in</th><th>Expires</th><th aria-label="Actions" /></tr>
                      </thead>
                      <tbody>
                        {g.items.slice(0, n).map((s) => (
                          <tr key={s.id}>
                            <td title={s.user_agent}>
                              {deviceLabel(s.user_agent)} {s.current && <Badge tone="green" dot>This session</Badge>}
                            </td>
                            <td><strong>{formatRelativeTime(s.last_used_at)}</strong><div className="wb-audit-sub">{whenText(s.last_used_at)}</div></td>
                            <td>{whenText(s.created_at)}</td>
                            <td>{whenText(s.expires_at)}</td>
                            <td>
                              <Button variant="danger" size="sm" loading={busy === s.id} disabled={s.current || busy !== null}
                                title={s.current ? 'This is the session you are using' : undefined} onClick={() => void revokeOne(s)}>
                                Revoke
                              </Button>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    {g.items.length > n && (
                      <div className="wb-audit-more">
                        <Button variant="ghost" size="sm" onClick={() => setShown({ ...shown, [g.id]: n + PAGE })}>
                          Show {Math.min(PAGE, g.items.length - n)} more ({g.items.length - n} hidden)
                        </Button>
                      </div>
                    )}
                  </div>
                )}
              </Card>
            )
          })}
        </div>
      )}
    </section>
  )
}
