// Audit & sessions — who did what (audit_log, filterable, paged) and every
// active sign-in with a Revoke button. Platform admins only.

import React from 'react'
import {
  ApiError,
  exportAuditCsv,
  listAudit,
  listAuditActions,
  listUsers,
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
import { SessionsSection } from './SessionsSection'
import type { AuditEntry } from '../lib/types'
import './pages.css'
import './AuditPage.css'

function whenText(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

function actionTone(action: string): 'green' | 'orange' | 'pink' | 'neutral' {
  if (/fail|reuse|revoked|delete|locked/.test(action)) return 'orange'
  if (/login|create|register/.test(action)) return 'green'
  return 'neutral'
}

export function AuditPage() {
  const usersQ = useAsync(listUsers, [])

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

  if (isAccessDenied(error)) {
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

  const users = usersQ.data ?? []

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

      <SessionsSection onChanged={() => void load()} />

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
