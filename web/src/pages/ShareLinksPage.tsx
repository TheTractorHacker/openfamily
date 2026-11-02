// Share links — every "anyone with the link" live-location link across the
// server, with a Revoke button. Tokens are never shown (only a hash is
// stored). Platform admins only.

import React from 'react'
import { ApiError, listAdminShareLinks, revokeAdminShareLink } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatTimeLeft } from '../lib/format'
import type { AdminShareLink } from '../lib/types'
import './pages.css'
import './AuditPage.css'

function whenText(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

const TONE = { active: 'green', expired: 'grey', revoked: 'orange' } as const

export function ShareLinksPage() {
  const linksQ = useAsync(listAdminShareLinks, [])
  const [filter, setFilter] = React.useState<'active' | 'all'>('active')
  const [revoking, setRevoking] = React.useState<string | null>(null)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  if (isAccessDenied(linksQ.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  if (linksQ.loading && !linksQ.data) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading share links…
        </div>
      </div>
    )
  }
  if (linksQ.error) {
    return (
      <div className="wb-page">
        <ErrorState title="Couldn’t load share links" description={linksQ.error.message} onRetry={linksQ.refetch} />
      </div>
    )
  }

  const all: AdminShareLink[] = linksQ.data ?? []
  const links = filter === 'active' ? all.filter((l) => l.status === 'active') : all

  const revoke = async (l: AdminShareLink) => {
    if (!window.confirm(`Stop this link for ${l.user_name}? Anyone using it loses access immediately.`)) return
    setRevoking(l.id)
    setMessage(null)
    try {
      await revokeAdminShareLink(l.id)
      setMessage({ tone: 'success', text: 'Link revoked.' })
      linksQ.refetch()
    } catch (e) {
      setMessage({ tone: 'error', text: e instanceof ApiError || e instanceof Error ? e.message : 'Request failed' })
    } finally {
      setRevoking(null)
    }
  }

  return (
    <div className="wb-page">
      <div className="wb-audit-sectionhead">
        <div style={{ marginRight: 'auto' }}>
          <h1 className="wb-page-title">Share links</h1>
          <p className="wb-page-subtitle">
            Temporary public links members created to share their live location. Revoking stops a link at once.
          </p>
        </div>
        <label className="wb-field" htmlFor="links-filter">
          <span className="wb-label">Show</span>
          <select
            id="links-filter"
            className="wb-select"
            value={filter}
            onChange={(e) => setFilter(e.target.value as 'active' | 'all')}
          >
            <option value="active">Active only</option>
            <option value="all">All (incl. expired and revoked)</option>
          </select>
        </label>
        <Button variant="secondary" size="sm" onClick={() => linksQ.refetch()}>
          Refresh
        </Button>
      </div>
      {message && (
        <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">
          {message.text}
        </p>
      )}
      {links.length === 0 ? (
        <EmptyState
          title={filter === 'active' ? 'No active share links' : 'No share links'}
          description="Links appear here when a member shares their location with someone outside the app."
        />
      ) : (
        <Card padded={false}>
          <div className="wb-audit-tablewrap">
            <table className="wb-table">
              <thead>
                <tr>
                  <th>Member</th>
                  <th>Label</th>
                  <th>Created</th>
                  <th>Expires</th>
                  <th>Status</th>
                  <th aria-label="Actions" />
                </tr>
              </thead>
              <tbody>
                {links.map((l) => (
                  <tr key={l.id}>
                    <td>
                      <div className="wb-audit-user">{l.user_name}</div>
                      <div className="wb-audit-sub">
                        {l.user_email}
                        {l.family_name ? ` · ${l.family_name}` : ''}
                      </div>
                    </td>
                    <td>{l.label || '—'}</td>
                    <td>{whenText(l.created_at)}</td>
                    <td title={whenText(l.expires_at)}>
                      {l.status === 'active' ? formatTimeLeft(l.expires_at) : whenText(l.expires_at)}
                    </td>
                    <td>
                      <Badge tone={TONE[l.status]}>{l.status}</Badge>
                    </td>
                    <td>
                      {l.status === 'active' && (
                        <Button
                          variant="danger"
                          size="sm"
                          loading={revoking === l.id}
                          disabled={revoking !== null}
                          onClick={() => void revoke(l)}
                        >
                          Revoke
                        </Button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </div>
  )
}
