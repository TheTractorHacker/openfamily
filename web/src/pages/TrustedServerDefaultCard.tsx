import React from 'react'
import { ApiError, getTrustedServerDefault, setTrustedServerDefault, type TrustedServerDefault } from '../lib/api'
import { trustedDefaultBlocker, trustedDefaultCanToggle } from '../lib/trustedDefault'
import { Card } from '../components/primitives'

export function TrustedServerDefaultCard() {
  const [state, setState] = React.useState<TrustedServerDefault | null>(null)
  const [busy, setBusy] = React.useState(false)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  React.useEffect(() => {
    let live = true
    getTrustedServerDefault()
      .then((r) => {
        if (live) setState(r)
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [])

  async function toggle(next: boolean) {
    if (busy || !state) return
    setBusy(true)
    setMessage(null)
    try {
      setState(await setTrustedServerDefault(next))
      setMessage({ tone: 'success', text: next ? 'Saved. The app now recommends this for new Private circles.' : 'Saved. The recommendation is off.' })
    } catch (err) {
      const text = err instanceof ApiError || err instanceof Error ? err.message : 'Could not save'
      setMessage({ tone: 'error', text })
    } finally {
      setBusy(false)
    }
  }

  const blocker = state ? trustedDefaultBlocker(state) : null
  const canToggle = state ? trustedDefaultCanToggle(state) : false

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Trust this server by default</h3>
      </div>
      <p className="wb-settings-section-help">
        For an instance whose owner runs and trusts the server (for example it feeds the map and Dawarich). When on, the
        app recommends &ldquo;Server can read (trusted)&rdquo; when someone turns on encryption for a circle, and reminds
        members of a Private circle once that the server can be allowed.
      </p>
      <div className="wb-settings-section wb-settings-section-flush">
        <label style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <input
            type="checkbox"
            checked={state?.trusted_server_default ?? false}
            disabled={busy || !state || !canToggle}
            onChange={(e) => toggle(e.target.checked)}
            aria-describedby="wb-trusted-default-notes"
          />
          Recommend trusting this server
        </label>
        <div id="wb-trusted-default-notes">
          <p className="wb-help">
            <strong>What it does:</strong> only changes which choice is preselected and a one-time reminder in the app.
          </p>
          <p className="wb-help">
            <strong>What it does not do:</strong> nobody is opted in. Every member of each circle is still asked, on their
            own phone, and can decline or withdraw at any time. The server never consents for anyone, and the server can
            read a circle only after every member has signed. People can still choose strict end-to-end instead.
          </p>
          {blocker && <p className="wb-error-text" role="status">{blocker}</p>}
        </div>
        {message && (
          <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{message.text}</p>
        )}
      </div>
    </Card>
  )
}
