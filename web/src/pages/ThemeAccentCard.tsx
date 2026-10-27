import React from 'react'
import { ApiError, getThemeSettings, updateThemeSettings } from '../lib/api'
import { Button, Card } from '../components/primitives'

// Built-in green first: choosing it clears the server default.
const BUILT_IN = '#8FD400'
const PRESETS: { name: string; hex: string }[] = [
  { name: 'Lime', hex: BUILT_IN },
  { name: 'Teal', hex: '#14B8A6' },
  { name: 'Sky', hex: '#0EA5E9' },
  { name: 'Indigo', hex: '#6366F1' },
  { name: 'Violet', hex: '#8B5CF6' },
  { name: 'Pink', hex: '#EC4899' },
  { name: 'Orange', hex: '#F97316' },
  { name: 'Amber', hex: '#F59E0B' },
]

const HEX = /^#[0-9A-Fa-f]{6}$/

export function ThemeAccentCard() {
  const [saved, setSaved] = React.useState('')
  const [color, setColor] = React.useState(BUILT_IN)
  const [busy, setBusy] = React.useState(false)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  React.useEffect(() => {
    let live = true
    getThemeSettings()
      .then((r) => {
        if (!live) return
        setSaved(r.default_accent)
        setColor(r.default_accent || BUILT_IN)
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [])

  const valid = HEX.test(color)
  const effective = color.toUpperCase() === BUILT_IN ? '' : color.toUpperCase()
  const dirty = valid && effective !== saved

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!dirty) return
    setBusy(true)
    setMessage(null)
    try {
      const r = await updateThemeSettings(effective)
      setSaved(r.default_accent)
      setMessage({ tone: 'success', text: 'Saved. Apps pick it up the next time they open.' })
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
        <h3 className="wb-settings-title">App accent color</h3>
      </div>
      <p className="wb-settings-section-help">
        The default highlight color for everyone&apos;s app. People can still pick their own in the app.
      </p>
      <form className="wb-settings-section wb-settings-section-flush" onSubmit={save}>
        <div role="radiogroup" aria-label="Preset colors" style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
          {PRESETS.map((p) => {
            const on = color.toUpperCase() === p.hex
            return (
              <button
                key={p.hex}
                type="button"
                role="radio"
                aria-checked={on}
                aria-label={p.name}
                title={p.name}
                onClick={() => setColor(p.hex)}
                disabled={busy}
                style={{
                  width: 36, height: 36, borderRadius: '50%', background: p.hex, cursor: 'pointer',
                  border: on ? '3px solid currentColor' : '2px solid rgba(128,128,128,.4)',
                }}
              />
            )
          })}
        </div>
        <label className="wb-field" htmlFor="wb-accent-hex">
          <span className="wb-label">Custom color</span>
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
            <input
              type="color"
              aria-label="Pick a color"
              value={valid ? color : BUILT_IN}
              onChange={(e) => setColor(e.target.value.toUpperCase())}
              disabled={busy}
            />
            <input id="wb-accent-hex" className="wb-input" value={color} maxLength={7}
              onChange={(e) => setColor(e.target.value.trim())} placeholder="#8FD400"
              spellCheck={false} autoComplete="off" disabled={busy} aria-invalid={!valid} />
          </div>
        </label>
        {message && (
          <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{message.text}</p>
        )}
        <Button type="submit" disabled={!dirty || busy}>{busy ? 'Saving…' : 'Save color'}</Button>
      </form>
    </Card>
  )
}
