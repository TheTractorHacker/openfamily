import React from 'react'
import { useUnsavedChanges } from '../lib/unsaved'
import { ApiError, getMapStyleSettings, saveMapStyleSettings, testMapStyle } from '../lib/api'
import { Button, Card } from '../components/primitives'
import type { MapStyleSettings } from '../lib/types'

const errText = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : 'Request failed')

/** Sets the vector map style URL used by the web and app maps (https only). */
export function MapStyleCard() {
  const [cur, setCur] = React.useState<MapStyleSettings | null>(null)
  const [value, setValue] = React.useState('')
  const [busy, setBusy] = React.useState<'save' | 'test' | null>(null)
  const [msg, setMsg] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  React.useEffect(() => {
    let live = true
    getMapStyleSettings()
      .then((r) => {
        if (!live) return
        setCur(r)
        setValue(r.map_style_url)
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [])

  useUnsavedChanges(!!cur && value.trim() !== cur.map_style_url, 'Map style')

  const run = async (kind: 'save' | 'test') => {
    setBusy(kind)
    setMsg(null)
    try {
      if (kind === 'test') {
        await testMapStyle(value.trim())
        setMsg({ tone: 'success', text: 'The style loads and looks valid.' })
      } else {
        const r = await saveMapStyleSettings(value.trim())
        setCur(r)
        setValue(r.map_style_url)
        setMsg({
          tone: 'success',
          text: r.map_style_url
            ? 'Saved. Maps pick it up on their next load; no restart needed.'
            : 'Cleared. Maps use the server default.',
        })
      }
    } catch (e) {
      setMsg({ tone: 'error', text: errText(e) })
    } finally {
      setBusy(null)
    }
  }

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Map style</h3>
      </div>
      <p className="wb-settings-section-help">
        A MapLibre / OpenMapTiles style JSON URL for the web and app maps. https only. Leave empty to use the server
        default
        {cur?.env_default ? ` (${cur.env_default})` : ' (OpenFreeMap)'}.
      </p>
      <div className="wb-settings-section wb-settings-section-flush">
        <label className="wb-field" htmlFor="map-style-url">
          <span className="wb-label">Style URL</span>
          <input
            id="map-style-url"
            className="wb-input"
            type="url"
            inputMode="url"
            placeholder="https://tiles.example.com/styles/liberty"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            disabled={busy !== null}
          />
        </label>
        <div className="wb-row">
          <Button variant="secondary" loading={busy === 'test'} disabled={busy !== null} onClick={() => void run('test')}>
            Test
          </Button>
          <Button loading={busy === 'save'} disabled={busy !== null} onClick={() => void run('save')}>
            Save
          </Button>
        </div>
        {msg && (
          <p className={msg.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">
            {msg.text}
          </p>
        )}
      </div>
    </Card>
  )
}
