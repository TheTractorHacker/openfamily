import React from 'react'
import {
  ApiError,
  clearDawarich,
  getDawarich,
  syncDawarichNow,
  testDawarich,
  updateDawarich,
} from '../lib/api'
import type { DawarichSettings } from '../lib/types'
import { Badge, Button, Card } from '../components/primitives'
import { DawarichUserMap } from './DawarichUserMap'

type FormMessage = { tone: 'success' | 'error'; text: string } | null

const DEFAULT_URL = 'https://maps.foleyit.com'
const DEFAULT_LOCAL_URL = 'http://10.1.1.1:30161'

function messageFromError(error: unknown, fallback: string): string {
  if (error instanceof ApiError || error instanceof Error) return error.message || fallback
  return fallback
}

function ago(iso: string | null): string {
  if (!iso) return 'never'
  const secs = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000))
  if (secs < 60) return 'just now'
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`
  return `${Math.floor(secs / 86400)}d ago`
}

export function DawarichSettingsCard() {
  const [settings, setSettings] = React.useState<DawarichSettings | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [baseUrl, setBaseUrl] = React.useState(DEFAULT_URL)
  const [localUrl, setLocalUrl] = React.useState(DEFAULT_LOCAL_URL)
  const [apiKey, setApiKey] = React.useState('')
  const [enabled, setEnabled] = React.useState(true)
  const [sendUnmapped, setSendUnmapped] = React.useState(false)
  const [busy, setBusy] = React.useState<'save' | 'test' | 'sync' | 'clear' | null>(null)
  const [message, setMessage] = React.useState<FormMessage>(null)

  const hydrate = React.useCallback((next: DawarichSettings) => {
    setSettings(next)
    if (next.base_url) setBaseUrl(next.base_url)
    setLocalUrl(next.local_url || DEFAULT_LOCAL_URL)
    setEnabled(next.base_url ? next.enabled : true)
    setSendUnmapped(next.send_unmapped)
    setApiKey('')
  }, [])

  React.useEffect(() => {
    getDawarich()
      .then(hydrate)
      .catch((e) => setMessage({ tone: 'error', text: messageFromError(e, 'Could not load Dawarich settings.') }))
      .finally(() => setLoading(false))
  }, [hydrate])

  const run = async (kind: NonNullable<typeof busy>, fn: () => Promise<string | void>) => {
    if (busy) return
    setBusy(kind)
    setMessage(null)
    try {
      const text = await fn()
      if (text) setMessage({ tone: 'success', text })
    } catch (e) {
      setMessage({ tone: 'error', text: messageFromError(e, 'Request failed.') })
    } finally {
      setBusy(null)
    }
  }

  const save = (event: React.FormEvent) => {
    event.preventDefault()
    void run('save', async () => {
      hydrate(
        await updateDawarich({
          base_url: baseUrl.trim(),
          local_url: localUrl.trim(),
          api_key: apiKey.trim(),
          enabled,
          send_unmapped: sendUnmapped,
          backfill_days: 0,
        })
      )
      return enabled ? 'Saved. New locations sync to Dawarich every minute.' : 'Saved. Sync is paused.'
    })
  }

  const configured = Boolean(settings?.base_url)
  const on = Boolean(configured && settings?.enabled)

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Dawarich sync</h3>
        <Badge tone={on ? 'green' : 'grey'} dot>
          {loading ? 'Checking…' : on ? 'Syncing' : 'Off'}
        </Badge>
      </div>
      <p className="wb-settings-section-help">
        Push every location fix to your Dawarich server for long-term timeline, stats and trips.
      </p>

      {settings && configured && (
        <p className="wb-help" role="status">
          Last sync {ago(settings.last_sync_at)} · {settings.total_sent.toLocaleString()} sent ·{' '}
          {settings.pending.toLocaleString()} waiting
          {settings.last_error && <> · <span className="wb-error-text">{settings.last_error}</span></>}
        </p>
      )}

      <form className="wb-settings-section wb-settings-section-flush" onSubmit={save}>
        <label className="wb-field" htmlFor="wb-dw-url">
          <span className="wb-label">Dawarich address</span>
          <input id="wb-dw-url" className="wb-input" type="url" value={baseUrl}
            onChange={(e) => setBaseUrl(e.target.value)} placeholder={DEFAULT_URL}
            autoComplete="off" spellCheck={false} disabled={Boolean(busy)} required />
        </label>
        <label className="wb-field" htmlFor="wb-dw-local">
          <span className="wb-label">Local address (optional)</span>
          <input id="wb-dw-local" className="wb-input" type="url" value={localUrl}
            onChange={(e) => setLocalUrl(e.target.value)} placeholder={DEFAULT_LOCAL_URL}
            autoComplete="off" spellCheck={false} disabled={Boolean(busy)} />
          <span className="wb-help">Tried when the public address can’t be reached.</span>
        </label>
        <label className="wb-field" htmlFor="wb-dw-key">
          <span className="wb-label">Main account API key (optional)</span>
          <input id="wb-dw-key" className="wb-input" type="password" value={apiKey}
            onChange={(e) => setApiKey(e.target.value)} autoComplete="off" spellCheck={false}
            disabled={Boolean(busy)}
            placeholder={settings?.api_key_set ? 'Leave blank to keep the current key' : 'Only needed to send unmapped people'} />
        </label>
        <label className="wb-field" style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
          <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)}
            disabled={Boolean(busy)} />
          <span className="wb-label">Sync automatically</span>
        </label>
        <label className="wb-field" style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
          <input type="checkbox" checked={sendUnmapped} onChange={(e) => setSendUnmapped(e.target.checked)}
            disabled={Boolean(busy)} />
          <span className="wb-label">Send everyone not mapped below to the main account</span>
        </label>

        <div className="wb-settings-form-actions">
          <Button type="submit" loading={busy === 'save'} disabled={Boolean(busy)}>Save</Button>
          <Button type="button" variant="secondary" loading={busy === 'test'}
            disabled={Boolean(busy) || !configured}
            onClick={() => void run('test', async () => `Connected to ${(await testDawarich()).reached}`)}>
            Test connection
          </Button>
          <Button type="button" variant="secondary" loading={busy === 'sync'}
            disabled={Boolean(busy) || !configured}
            onClick={() => void run('sync', async () => {
              const next = await syncDawarichNow()
              setSettings(next)
              return next.last_error ? undefined : `Synced. ${next.pending} still waiting.`
            })}>
            Sync now
          </Button>
          {configured && (
            <Button type="button" variant="ghost" loading={busy === 'clear'} disabled={Boolean(busy)}
              onClick={() => void run('clear', async () => {
                hydrate(await clearDawarich())
                return 'Disconnected from Dawarich.'
              })}>
              Disconnect
            </Button>
          )}
        </div>
        {message && (
          <p className={`wb-profile-message wb-profile-message-${message.tone}`}
            role={message.tone === 'error' ? 'alert' : 'status'}>
            {message.text}
          </p>
        )}
      </form>
      <DawarichUserMap onChanged={() => void getDawarich().then(setSettings).catch(() => undefined)} />
    </Card>
  )
}
