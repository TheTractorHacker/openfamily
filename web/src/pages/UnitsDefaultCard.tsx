import React from 'react'
import { ApiError, getThemeSettings, updateDefaultUnits } from '../lib/api'
import { Card } from '../components/primitives'

type Units = 'imperial' | 'metric'

export function UnitsDefaultCard() {
  const [units, setUnits] = React.useState<Units>('imperial')
  const [busy, setBusy] = React.useState(false)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  React.useEffect(() => {
    let live = true
    getThemeSettings()
      .then((r) => {
        if (live) setUnits(r.default_units === 'metric' ? 'metric' : 'imperial')
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [])

  async function choose(next: Units) {
    if (next === units || busy) return
    setBusy(true)
    setMessage(null)
    try {
      const r = await updateDefaultUnits(next)
      setUnits(r.default_units === 'metric' ? 'metric' : 'imperial')
      setMessage({ tone: 'success', text: 'Saved. Applies to people who have not picked their own.' })
    } catch (err) {
      const text = err instanceof ApiError || err instanceof Error ? err.message : 'Could not save'
      setMessage({ tone: 'error', text })
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Distance &amp; speed units</h3>
      </div>
      <p className="wb-settings-section-help">
        The default for everyone&apos;s app and for server-written notifications. People can choose their own in the
        app&apos;s Settings.
      </p>
      <div className="wb-settings-section wb-settings-section-flush">
        <div role="radiogroup" aria-label="Default units" style={{ display: 'flex', gap: 16 }}>
          {([['imperial', 'Miles (mi, mph)'], ['metric', 'Kilometers (km, km/h)']] as [Units, string][]).map(
            ([value, label]) => (
              <label key={value} style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input
                  type="radio"
                  name="wb-default-units"
                  checked={units === value}
                  disabled={busy}
                  onChange={() => choose(value)}
                />
                {label}
              </label>
            ),
          )}
        </div>
        {message && (
          <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{message.text}</p>
        )}
      </div>
    </Card>
  )
}
