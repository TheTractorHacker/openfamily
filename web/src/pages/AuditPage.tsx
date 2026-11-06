// Audit & sessions — who did what (audit_log, filterable, paged) and every
// active sign-in with a Revoke button. Platform admins only.

import React from 'react'
import {
  ApiError,
  exportAuditCsv,
  listAdminSessions,
  listAudit,
  listAuditActions,
  listUsers,
  revokeAdminSession,
} from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import {
  AccessDenied,
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorState,
  Mono,
  Spinner,
} from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import type { AuditEntry } from '../lib/types'
import './pages.css'
import './AuditPage.css'

function whenText(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

/** A short device label from a raw User-Agent string. */
function deviceLabel(ua: string): string {
  if (!ua) return 'Unknown device'
  if (/OpenFamily/i.test(ua)) return ua.length > 60 ? `${ua.slice(0, 57)}…` : ua
  const browser = /Edg\//.test(ua)
    ? 'Edge'
    : /Chrome\//.test(ua)
      ? 'Chrome'
      : /Firefox\//.test(ua)
        ? 'Firefox'
        : /Safari\//.test(ua)
          ? 'Safari'
          : /okhttp|Dart/i.test(ua)
            ? 'Mobile app'
            : 'Browser'
  const os = /Android/.test(ua)
    ? 'Android'
    : /iPhone|iPad|iOS/.test(ua)
      ? 'iOS'
      : /Windows/.test(ua)
        ? 'Windows'
        : /Mac OS X/.test(ua)
          ? 'macOS'
          : /Linux/.test(ua)
            ? 'Linux'
            : ''
  return os ? `${browser} on ${os}` : browser
}

function actionTone(action: string): 'green' | 'orange' | 'pink' | 'neutral' {
  if (/fail|reuse|revoked|delete|locked/.test(action)) return 'orange'
  if (/login|create|register/.test(action)) return 'green'
  return 'neutral'
}

export function AuditPage() {
  // ---- sessions ----
  const [sessionUser, setSessionUser] = React.useState('')
  const usersQ = useAsync(listUsers, [])
  const sessionsQ = useAsync(() => listAdminSessions(sessionUser || undefined), [sessionUser])
  const [revoking, setRevoking] = React.useState<string | null>(null)
  const [sessionMsg, setSessionMsg] = React.useState<string | null>(null)

  // ---- audit ----
  const actionsQ = useAsync(listAuditActions, [])
  const [filters, setFilters] = React.useState({ user_id: '', action: '', q: '', from: '', to: '' })
  const [applied, setApplied] = React.useState(filters)
  const [entries, setEntries] = React.useState<AuditEntry[]>([])
  const [next, setNext] = React.useState<number | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [exporting, setExporting] = React.useState(false)
  const [exportMsg, setExportMsg] = React.useState<string | null>(null)
  const [loadingMore, setLoadingMore] = React.useState(false)
  const [error, setError] = React.useState<{ status: number; message: string } | null>(null)

  const load = React.useCallback(
    async (before?: number) => {
      before ? setLoadingMore(true) : setLoading(true)
      setError(null)
      try {
        const page = await listAudit({ ...applied, before_id: before, limit: 50 })
        setEntries((cur) => (before ? [...cur, ...page.entries] : page.entries))
        setNext(page.next_before_id)
      } catch (e) {
        setError({
          status: e instanceof ApiError ? e.status : 0,
          message: e instanceof Error ? e.message : 'Request failed',
        })
      } finally {
        setLoading(false)
        setLoadingMore(false)
      }
    },
    [applied],
  )
  React.useEffect(() => {
    void load()
  }, [load])

  if (isAccessDenied(error) || isAccessDenied(sessionsQ.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  const exportCsv = async () => {
    setExporting(true)
    setExportMsg(null)
    try {
      const blob = await exportAuditCsv(applied)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `audit-${new Date().toISOString().slice(0, 10)}.csv`
      document.body.appendChild(a)
      a.click()
      a.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    } catch (e) {
      setExportMsg(e instanceof Error ? e.message : 'Export failed.')
    } finally {
      setExporting(false)
    }
  }

  const revoke = async (id: string, who: string) => {
    if (!window.confirm(`Sign ${who} out of this device? Their refresh token stops working now.`)) return
    setRevoking(id)
    setSessionMsg(null)
    try {
      await revokeAdminSession(id)
      setSessionMsg('Session revoked.')
      sessionsQ.refetch()
      void load()
    } catch (e) {
      setSessionMsg(e instanceof Error ? e.message : 'Could not revoke the session.')
    } finally {
      setRevoking(null)
    }
  }

  const users = usersQ.data ?? []
  const sessions = sessionsQ.data ?? []

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Audit &amp; sessions</h1>
          <p className="wb-page-subtitle">
            Active sign-ins you can revoke, and the record of what happened on this server.
          </p>
        </div>
      </div>

      <section className="wb-audit-section" aria-labelledby="sessions-h">
        <div className="wb-audit-sectionhead">
          <h2 id="sessions-h" className="wb-audit-h2">
            Active sessions
          </h2>
          <label className="wb-field" htmlFor="sessions-user">
            <span className="wb-label">User</span>
            <select
              id="sessions-user"
              className="wb-select"
              value={sessionUser}
              onChange={(e) => setSessionUser(e.target.value)}
            >
              <option value="">Everyone</option>
              {users.map((u) => (
                <option key={u.id} value={u.id}>
                  {u.name} ({u.email})
                </option>
              ))}
            </select>
          </label>
          <Button variant="secondary" size="sm" onClick={() => sessionsQ.refetch()}>
            Refresh
          </Button>
        </div>
        {sessionMsg && (
          <p className="wb-help" role="status">
            {sessionMsg}
          </p>
        )}
        {sessionsQ.loading && !sessionsQ.data ? (
          <div className="wb-page-loading">
            <Spinner /> Loading sessions…
          </div>
        ) : sessionsQ.error ? (
          <ErrorState
            title="Couldn’t load sessions"
            description={sessionsQ.error.message}
            onRetry={sessionsQ.refetch}
          />
        ) : sessions.length === 0 ? (
          <EmptyState title="No active sessions" description="Nobody is signed in right now." />
        ) : (
          <Card padded={false}>
            <div className="wb-audit-tablewrap">
              <table className="wb-table">
                <thead>
                  <tr>
                    <th>User</th>
                    <th>Device</th>
                    <th>Signed in</th>
                    <th>Last active</th>
                    <th>Expires</th>
                    <th aria-label="Actions" />
                  </tr>
                </thead>
                <tbody>
                  {sessions.map((s) => (
                    <tr key={s.id}>
                      <td>
                        <div className="wb-audit-user">{s.user_name}</div>
                        <div className="wb-audit-sub">{s.user_email}</div>
                      </td>
                      <td title={s.user_agent}>{deviceLabel(s.user_agent)}</td>
                      <td>{whenText(s.created_at)}</td>
                      <td>{formatRelativeTime(s.last_used_at)}</td>
                      <td>{whenText(s.expires_at)}</td>
                      <td>
                        <Button
                          variant="danger"
                          size="sm"
                          loading={revoking === s.id}
                          disabled={revoking !== null}
                          onClick={() => void revoke(s.id, s.user_name)}
                        >
                          Revoke
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
        )}
      </section>

      <section className="wb-audit-section" aria-labelledby="audit-h">
        <div className="wb-audit-sectionhead">
          <h2 id="audit-h" className="wb-audit-h2">
            Audit log
          </h2>
        </div>
        <form
          className="wb-audit-filters"
          onSubmit={(e) => {
            e.preventDefault()
            setApplied(filters)
          }}
        >
          <label className="wb-field" htmlFor="audit-user">
            <span className="wb-label">Actor</span>
            <select
              id="audit-user"
              className="wb-select"
              value={filters.user_id}
              onChange={(e) => setFilters({ ...filters, user_id: e.target.value })}
            >
              <option value="">Anyone</option>
              {users.map((u) => (
                <option key={u.id} value={u.id}>
                  {u.name}
                </option>
              ))}
            </select>
          </label>
          <label className="wb-field" htmlFor="audit-action">
            <span className="wb-label">Action</span>
            <input
              id="audit-action"
              className="wb-input"
              list="audit-actions"
              placeholder="e.g. auth.* or place.delete"
              value={filters.action}
              onChange={(e) => setFilters({ ...filters, action: e.target.value })}
            />
            <datalist id="audit-actions">
              {(actionsQ.data ?? []).map((a) => (
                <option key={a} value={a} />
              ))}
            </datalist>
          </label>
          <label className="wb-field" htmlFor="audit-q">
            <span className="wb-label">Detail contains</span>
            <input
              id="audit-q"
              className="wb-input"
              value={filters.q}
              onChange={(e) => setFilters({ ...filters, q: e.target.value })}
            />
          </label>
          <label className="wb-field" htmlFor="audit-from">
            <span className="wb-label">From</span>
            <input
              id="audit-from"
              type="date"
              className="wb-input"
              value={filters.from}
              onChange={(e) => setFilters({ ...filters, from: e.target.value })}
            />
          </label>
          <label className="wb-field" htmlFor="audit-to">
            <span className="wb-label">To</span>
            <input
              id="audit-to"
              type="date"
              className="wb-input"
              value={filters.to}
              onChange={(e) => setFilters({ ...filters, to: e.target.value })}
            />
          </label>
          <Button type="submit">Apply</Button>
          <Button
            type="button"
            variant="ghost"
            onClick={() => {
              const clear = { user_id: '', action: '', q: '', from: '', to: '' }
              setFilters(clear)
              setApplied(clear)
            }}
          >
            Clear
          </Button>
          <Button type="button" variant="secondary" loading={exporting} onClick={() => void exportCsv()}>
            Export CSV
          </Button>
        </form>
        {exportMsg && (
          <p className="wb-error-text" role="status">
            {exportMsg}
          </p>
        )}

        {loading && entries.length === 0 ? (
          <div className="wb-page-loading">
            <Spinner /> Loading audit log…
          </div>
        ) : error ? (
          <ErrorState title="Couldn’t load the audit log" description={error.message} onRetry={() => void load()} />
        ) : entries.length === 0 ? (
          <EmptyState title="Nothing matches" description="Try widening the filters." />
        ) : (
          <Card padded={false}>
            <div className="wb-audit-tablewrap">
              <table className="wb-table">
                <thead>
                  <tr>
                    <th>When</th>
                    <th>Who</th>
                    <th>Action</th>
                    <th>Detail</th>
                    <th>IP</th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map((e) => (
                    <tr key={e.id}>
                      <td className="wb-audit-nowrap">{whenText(e.created_at)}</td>
                      <td>
                        <div className="wb-audit-user">{e.user_name || 'System'}</div>
                        {e.family_name && <div className="wb-audit-sub">{e.family_name}</div>}
                      </td>
                      <td>
                        <Badge tone={actionTone(e.action)}>{e.action}</Badge>
                      </td>
                      <td className="wb-audit-detail">{e.detail || '—'}</td>
                      <td>{e.ip_address ? <Mono>{e.ip_address}</Mono> : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
        )}
        {next !== null && (
          <div className="wb-audit-more">
            <Button variant="secondary" loading={loadingMore} onClick={() => void load(next)}>
              Load older entries
            </Button>
          </div>
        )}
      </section>
    </div>
  )
}
