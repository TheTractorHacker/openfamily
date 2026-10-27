import React from 'react'
import { ApiError, listDawarichUsers, removeDawarichUser, saveDawarichUser } from '../lib/api'
import type { DawarichUser } from '../lib/types'
import { Badge, Button, Spinner } from '../components/primitives'

const BACKFILL_OPTIONS = [
  { days: 0, label: 'Start from now (keeps existing Dawarich data untouched)' },
  { days: 1, label: 'Also send the last day' },
  { days: 7, label: 'Also send the last 7 days' },
  { days: 30, label: 'Also send the last 30 days' },
  { days: 90, label: 'Also send everything we have (90 days)' },
]

function errText(error: unknown): string {
  if (error instanceof ApiError || error instanceof Error) return error.message
  return 'Request failed.'
}

function UserRow({
  user,
  onChange,
}: {
  user: DawarichUser
  onChange: (users: DawarichUser[]) => void
}) {
  const [apiKey, setApiKey] = React.useState('')
  const [label, setLabel] = React.useState(user.label)
  const [enabled, setEnabled] = React.useState(user.mapped ? user.enabled : true)
  const [days, setDays] = React.useState(0)
  const [busy, setBusy] = React.useState<'save' | 'remove' | null>(null)
  const [error, setError] = React.useState<string | null>(null)

  const save = async () => {
    setBusy('save')
    setError(null)
    try {
      onChange(await saveDawarichUser(user.user_id, { api_key: apiKey.trim(), label, enabled, backfill_days: days }))
      setApiKey('')
    } catch (e) {
      setError(errText(e))
    } finally {
      setBusy(null)
    }
  }

  const remove = async () => {
    setBusy('remove')
    setError(null)
    try {
      onChange(await removeDawarichUser(user.user_id))
      setApiKey('')
    } catch (e) {
      setError(errText(e))
    } finally {
      setBusy(null)
    }
  }

  const id = `wb-dwu-${user.user_id}`
  const disabled = busy !== null

  return (
    <li className="wb-settings-section wb-settings-section-flush" style={{ borderTop: '1px solid var(--border, #e5e5e5)', paddingTop: 12 }}>
      <div className="wb-settings-title-row">
        <strong>{user.name || user.email}</strong>
        <Badge tone={user.mapped ? (user.enabled ? 'green' : 'grey') : 'neutral'} dot>
          {user.mapped ? (user.enabled ? 'Mapped' : 'Paused') : 'Not mapped'}
        </Badge>
      </div>
      <span className="wb-help">
        {user.email}
        {user.mapped && <> · {user.total_sent.toLocaleString()} sent</>}
      </span>

      <label className="wb-field" htmlFor={`${id}-key`}>
        <span className="wb-label">Their Dawarich API key</span>
        <input id={`${id}-key`} className="wb-input" type="password" value={apiKey}
          onChange={(e) => setApiKey(e.target.value)} autoComplete="off" spellCheck={false} disabled={disabled}
          placeholder={user.mapped ? 'Leave blank to keep the current key' : 'From that person’s Dawarich account'} />
      </label>
      <label className="wb-field" htmlFor={`${id}-label`}>
        <span className="wb-label">Dawarich account name (optional note)</span>
        <input id={`${id}-label`} className="wb-input" value={label} maxLength={120}
          onChange={(e) => setLabel(e.target.value)} disabled={disabled} placeholder="e.g. blake@dawarich" />
      </label>
      {!user.mapped && (
        <label className="wb-field" htmlFor={`${id}-days`}>
          <span className="wb-label">What to send first</span>
          <select id={`${id}-days`} className="wb-input" value={days}
            onChange={(e) => setDays(Number(e.target.value))} disabled={disabled}>
            {BACKFILL_OPTIONS.map((o) => <option key={o.days} value={o.days}>{o.label}</option>)}
          </select>
        </label>
      )}
      <label className="wb-field" style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
        <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} disabled={disabled} />
        <span className="wb-label">Sync this person</span>
      </label>

      <div className="wb-settings-form-actions">
        <Button type="button" size="sm" loading={busy === 'save'} disabled={disabled || (!user.mapped && !apiKey.trim())}
          onClick={() => void save()}>
          {user.mapped ? 'Save mapping' : 'Map user'}
        </Button>
        {user.mapped && (
          <Button type="button" size="sm" variant="ghost" loading={busy === 'remove'} disabled={disabled}
            onClick={() => void remove()}>
            Remove mapping
          </Button>
        )}
      </div>
      {user.last_error && <p className="wb-error-text" role="alert">{user.last_error}</p>}
      {error && <p className="wb-error-text" role="alert">{error}</p>}
    </li>
  )
}

/** Maps each OpenFamily account to its own Dawarich account (API key). */
export function DawarichUserMap({ onChanged }: { onChanged?: () => void }) {
  const [users, setUsers] = React.useState<DawarichUser[] | null>(null)
  const [loadError, setLoadError] = React.useState<string | null>(null)

  React.useEffect(() => {
    listDawarichUsers().then(setUsers).catch((e) => setLoadError(errText(e)))
  }, [])

  const update = (next: DawarichUser[]) => {
    setUsers(next)
    onChanged?.()
  }

  return (
    <div className="wb-settings-section wb-settings-section-flush">
      <h4 className="wb-label">User mapping</h4>
      <p className="wb-settings-section-help">
        Each person’s locations go to their own Dawarich account. Sync only adds points; nothing is
        ever deleted or changed in Dawarich. People who are not mapped are skipped
        unless you turn on “send everyone else” above.
      </p>
      {loadError && <p className="wb-error-text" role="alert">{loadError}</p>}
      {!users && !loadError && <Spinner />}
      {users && (
        <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'grid', gap: 12 }}>
          {users.map((u) => <UserRow key={u.user_id} user={u} onChange={update} />)}
        </ul>
      )}
    </div>
  )
}
