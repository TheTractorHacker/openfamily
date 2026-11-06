// Encryption keys: every registered device key (public data only) and each
// circle's end-to-end key epoch. The server holds no private keys, so nothing
// here can decrypt anything; the page exists so the operator can compare these
// fingerprints with what members see on their phones (Settings, Security,
// Encryption keys). Platform admins only.

import React from 'react'
import { listE2eeKeys } from '../lib/api'
import type { E2eeAdminDevice } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { PageHeader, Section } from '../components/patterns'
import './pages.css'
import './AuditPage.css'

const KIND_LABEL: Record<string, string> = {
  recovery: 'Recovery phrase',
  web: 'Web viewer (reads decrypted positions)',
  service: 'Bridge (reads decrypted positions, e.g. Dawarich)',
  device: 'Phone',
}

function whenText(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

export function EncryptionKeysPage() {
  const q = useAsync(listE2eeKeys, [])
  const [showRevoked, setShowRevoked] = React.useState(false)

  if (isAccessDenied(q.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  if (q.loading && !q.data) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading encryption keys…
        </div>
      </div>
    )
  }
  if (q.error) {
    return (
      <div className="wb-page">
        <ErrorState title="Couldn’t load encryption keys" description={q.error.message} onRetry={q.refetch} />
      </div>
    )
  }

  const devices: E2eeAdminDevice[] = (q.data?.devices ?? []).filter((d) => showRevoked || !d.revoked_at)
  const circles = q.data?.circles ?? []

  return (
    <div className="wb-page">
      <PageHeader
        title="Encryption keys"
        subtitle={
          <>
            Public device keys and circle key epochs. The server never holds a private key or a readable circle key.
            Compare a fingerprint with the member’s phone (Settings, Security, Encryption keys). On the server, run{' '}
            <code className="wb-inline-code">server e2ee-fingerprints</code> or{' '}
            <code className="wb-inline-code">server e2ee-log-head</code>.
          </>
        }
        actions={
          <>
        <label className="wb-field" htmlFor="e2ee-revoked">
          <span className="wb-label">Show</span>
          <select
            id="e2ee-revoked"
            className="wb-select"
            value={showRevoked ? 'all' : 'active'}
            onChange={(e) => setShowRevoked(e.target.value === 'all')}
          >
            <option value="active">Active keys</option>
            <option value="all">All (incl. revoked)</option>
          </select>
        </label>
        <Button variant="secondary" size="sm" onClick={() => q.refetch()}>
          Refresh
        </Button>
          </>
        }
      />

      <Section title="Circles">
      {circles.length === 0 ? (
        <EmptyState title="No private circles" description="Circles appear here once an admin turns on Private circle in the app." />
      ) : (
        <Card padded={false}>
          <div className="wb-audit-tablewrap">
            <table className="wb-table">
              <thead>
                <tr>
                  <th>Circle</th>
                  <th>Mode</th>
                  <th>Epoch</th>
                  <th>Members</th>
                  <th>Wrapped keys (this epoch)</th>
                  <th>Last change</th>
                </tr>
              </thead>
              <tbody>
                {circles.map((c) => (
                  <tr key={c.id}>
                    <td>{c.name}</td>
                    <td>
                      <Badge tone={c.mode === 'private' ? 'green' : 'grey'}>{c.mode}</Badge>
                      {c.rekey_required && <Badge tone="orange">new key needed</Badge>}
                    </td>
                    <td>{c.epoch}</td>
                    <td>{c.members}</td>
                    <td>{c.wrapped_keys}</td>
                    <td>{whenText(c.updated_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
      </Section>

      <Section title="Keys">
      {devices.length === 0 ? (
        <EmptyState title="No keys registered" description="Members register keys from the app (Settings, Security, Encryption keys)." />
      ) : (
        <Card padded={false}>
          <div className="wb-audit-tablewrap">
            <table className="wb-table">
              <thead>
                <tr>
                  <th>Member</th>
                  <th>Type</th>
                  <th>Fingerprint (short)</th>
                  <th>Fingerprint (digits)</th>
                  <th>Created</th>
                  <th>State</th>
                </tr>
              </thead>
              <tbody>
                {devices.map((d) => (
                  <tr key={d.device_id}>
                    <td>
                      <div className="wb-audit-user">{d.user_name}</div>
                      <div className="wb-audit-sub">{d.email}</div>
                    </td>
                    <td>{KIND_LABEL[d.kind] ?? 'Device'}</td>
                    <td>
                      <code>{d.short}</code>
                    </td>
                    <td title={d.fingerprint}>
                      <code>{d.digits}</code>
                    </td>
                    <td>{whenText(d.created_at)}</td>
                    <td>
                      {d.revoked_at ? (
                        <Badge tone="orange">revoked ({d.revoked_reason ?? 'revoked'})</Badge>
                      ) : (
                        <Badge tone="green">active</Badge>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
      </Section>
    </div>
  )
}
