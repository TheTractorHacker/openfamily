import React from 'react'
import { ApiError, getAdminCompat, saveAdminCompat } from '../lib/api'
import { COMPAT_LABEL, COMPAT_TONE, describePolicy, isVersionInput, usersByStatus } from '../lib/compat'
import { formatRelativeTime } from '../lib/format'
import { Badge, Button, Card } from '../components/primitives'
import type { AdminCompat } from '../lib/types'

const errText = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : 'Request failed')

/**
 * App versions in use, who is outside the support window, and the window
 * setting (docs/api-compat.md). Apps announce their version in X-App-Version;
 * the server only records it, it never blocks anyone unless enforcement is on.
 */
export function AppVersionsCard() {
  const [data, setData] = React.useState<AdminCompat | null>(null)
  const [override, setOverride] = React.useState('')
  const [enforce, setEnforce] = React.useState(false)
  const [busy, setBusy] = React.useState(false)
  const [msg, setMsg] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  const apply = (r: AdminCompat) => {
    setData(r)
    setOverride(r.policy.override)
    setEnforce(r.policy.enforce_writes)
  }

  React.useEffect(() => {
    let live = true
    getAdminCompat()
      .then((r) => live && apply(r))
      .catch((e) => live && setMsg({ tone: 'error', text: errText(e) }))
    return () => {
      live = false
    }
  }, [])

  const save = async () => {
    const o = override.trim()
    if (o && !isVersionInput(o)) {
      setMsg({ tone: 'error', text: 'Enter a version like 0.16.0, or leave empty for the rolling window.' })
      return
    }
    setBusy(true)
    setMsg(null)
    try {
      apply(await saveAdminCompat({ min_supported_override: o, enforce_writes: enforce }))
      setMsg({ tone: 'success', text: 'Saved.' })
    } catch (e) {
      setMsg({ tone: 'error', text: errText(e) })
    } finally {
      setBusy(false)
    }
  }

  const counts = data ? usersByStatus(data.versions) : null

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">App versions</h3>
      </div>
      {data ? (
        <>
          <p className="wb-settings-section-help">
            {describePolicy(data.policy)} Latest known release: {data.policy.latest_version}.{' '}
            {data.users_with_version} of {data.users_total} users have reported an app version in the last 90 days.
            {counts && counts.required > 0 && ` ${counts.required} are outside the window.`}
          </p>
          {data.versions.length === 0 ? (
            <p className="wb-help">No app has reported a version yet. Apps from this release on do.</p>
          ) : (
            <div className="wb-table-wrap">
            <table className="wb-table" aria-label="App versions in use">
              <thead>
                <tr>
                  <th>Version</th>
                  <th>Platform</th>
                  <th>Users</th>
                  <th>Status</th>
                  <th>Last seen</th>
                </tr>
              </thead>
              <tbody>
                {data.versions.map((v) => (
                  <tr key={`${v.app_version}|${v.platform}`}>
                    <td>{v.app_version}</td>
                    <td>{v.platform || 'unknown'}</td>
                    <td>{v.users}</td>
                    <td>
                      <Badge tone={COMPAT_TONE[v.status]}>{COMPAT_LABEL[v.status]}</Badge>
                    </td>
                    <td title={new Date(v.last_seen).toLocaleString()}>{formatRelativeTime(v.last_seen)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            </div>
          )}
          {data.outside_window.length > 0 && (
            <>
              <h4 className="wb-settings-title">Outside the window</h4>
              <ul className="wb-help" aria-label="Users outside the support window">
                {data.outside_window.map((u) => (
                  <li key={u.user_id}>
                    {u.name || u.email} ({u.email}) runs {u.app_version}
                    {u.platform ? ` on ${u.platform}` : ''}, last seen {formatRelativeTime(u.last_seen)}
                  </li>
                ))}
              </ul>
            </>
          )}
          <div className="wb-settings-section wb-settings-section-flush">
            <label className="wb-field" htmlFor="compat-min">
              <span className="wb-label">Minimum supported version (override)</span>
              <input
                id="compat-min"
                className="wb-input"
                placeholder={data.policy.env_min_supported || data.policy.window[0] + '.0'}
                value={override}
                onChange={(e) => setOverride(e.target.value)}
                disabled={busy}
              />
            </label>
            <label className="wb-field" htmlFor="compat-enforce">
              <span className="wb-label">
                <input
                  id="compat-enforce"
                  type="checkbox"
                  checked={enforce}
                  onChange={(e) => setEnforce(e.target.checked)}
                  disabled={busy}
                />{' '}
                Refuse location uploads from apps below the minimum (HTTP 426)
              </span>
            </label>
            <div className="wb-row">
              <Button loading={busy} disabled={busy} onClick={() => void save()}>
                Save
              </Button>
            </div>
          </div>
        </>
      ) : (
        <p className="wb-help">Loading...</p>
      )}
      {msg && (
        <p className={msg.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">
          {msg.text}
        </p>
      )}
    </Card>
  )
}
