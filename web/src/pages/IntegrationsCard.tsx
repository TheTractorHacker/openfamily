import React from 'react'
import {
  ApiError,
  createHaToken,
  listHaCircles,
  listHaTokens,
  revokeHaToken,
  testHaWebhook,
  updateHaToken,
} from '../lib/api'
import { HA_EVENT_INFO, HA_SCOPE_INFO } from '../lib/haTypes'
import type { HaCircleChoice, HaEventKind, HaScope, HaToken } from '../lib/haTypes'
import { ago, haSnippets } from '../lib/haSnippets'
import { useMe } from '../lib/me'
import { Badge, Button, Card, CopyButton, EmptyState } from '../components/primitives'
import './IntegrationsCard.css'

type Msg = { tone: 'success' | 'error'; text: string } | null

function errText(e: unknown, fallback: string): string {
  if (e instanceof ApiError || e instanceof Error) return e.message || fallback
  return fallback
}

function circleLabel(c: HaCircleChoice): string {
  return c.e2ee_mode === 'private' ? `${c.name} (Private)` : c.name
}

export function IntegrationsCard() {
  const { isPlatformAdmin } = useMe()
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  const [tokens, setTokens] = React.useState<HaToken[] | null>(null)
  const [circles, setCircles] = React.useState<HaCircleChoice[]>([])
  const [loadError, setLoadError] = React.useState<string | null>(null)
  const [creating, setCreating] = React.useState(false)
  const [name, setName] = React.useState('Home Assistant')
  const [scopes, setScopes] = React.useState<Set<HaScope>>(new Set(['presence', 'events']))
  const [picked, setPicked] = React.useState<Set<string>>(new Set())
  const [busy, setBusy] = React.useState<string | null>(null)
  const [msg, setMsg] = React.useState<Msg>(null)
  const [fresh, setFresh] = React.useState<HaToken | null>(null)
  const [openId, setOpenId] = React.useState<string | null>(null)

  const reload = React.useCallback(async () => {
    try {
      const [t, c] = await Promise.all([listHaTokens(), listHaCircles()])
      setTokens(t)
      setCircles(c)
      setLoadError(null)
    } catch (e) {
      setLoadError(errText(e, 'Could not load integrations.'))
    }
  }, [])
  React.useEffect(() => {
    void reload()
  }, [reload])

  const circleName = (id: string) => circles.find((c) => c.id === id)?.name ?? 'a circle you left'
  const toggle = <T,>(set: Set<T>, v: T): Set<T> => {
    const n = new Set(set)
    if (n.has(v)) n.delete(v)
    else n.add(v)
    return n
  }

  const create = async (e: React.FormEvent) => {
    e.preventDefault()
    if (busy) return
    setBusy('create')
    setMsg(null)
    try {
      const t = await createHaToken({
        name: name.trim(),
        scopes: [...scopes],
        circle_ids: [...picked],
      })
      setFresh(t)
      setCreating(false)
      setPicked(new Set())
      await reload()
    } catch (err) {
      setMsg({ tone: 'error', text: errText(err, 'Could not create the token.') })
    } finally {
      setBusy(null)
    }
  }

  const revoke = async (t: HaToken) => {
    if (busy || !window.confirm(`Revoke "${t.name}"? Home Assistant loses access immediately.`)) return
    setBusy(t.id)
    try {
      await revokeHaToken(t.id)
      if (fresh?.id === t.id) setFresh(null)
      setMsg({ tone: 'success', text: `Revoked "${t.name}".` })
      await reload()
    } catch (err) {
      setMsg({ tone: 'error', text: errText(err, 'Could not revoke the token.') })
    } finally {
      setBusy(null)
    }
  }

  const count = tokens?.length ?? 0
  return (
    <Card className="wb-ha-card">
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Integrations · Home Assistant</h3>
        <Badge tone={count ? 'green' : 'grey'} dot>
          {tokens === null ? 'Checking…' : count ? `${count} token${count === 1 ? '' : 's'}` : 'Not connected'}
        </Badge>
      </div>
      <p className="wb-settings-section-help">
        Let your own Home Assistant read who is home, battery and (if you allow it) position, and receive arrival, SOS and
        crash events. A token is read-only, limited to the circles you pick, and can be revoked at any time. A Private
        (end-to-end encrypted) circle never exposes positions unless it uses trusted-server mode.
      </p>

      {loadError && <p className="wb-profile-message wb-profile-message-error" role="alert">{loadError}</p>}

      {(fresh?.token || fresh?.webhook_secret) && (
        <div className="wb-ha-reveal" role="status">
          <strong>Copy these now. They are shown only once.</strong>
          {fresh.token && (
            <div className="wb-ha-secret">
              <span className="wb-label">Access token</span>
              <code>{fresh.token}</code>
              <CopyButton value={fresh.token} label="Copy token" />
            </div>
          )}
          {fresh.webhook_secret && (
            <div className="wb-ha-secret">
              <span className="wb-label">Webhook signing secret</span>
              <code>{fresh.webhook_secret}</code>
              <CopyButton value={fresh.webhook_secret} label="Copy signing secret" />
            </div>
          )}
          {fresh.token && haSnippets(origin, fresh.token).map((s) => (
            <details key={s.id} className="wb-ha-snippet" open={s.id === 'hacs'}>
              <summary>{s.title}</summary>
              <pre>{s.text}</pre>
              <CopyButton value={s.text} label={`Copy ${s.title}`} />
            </details>
          ))}
          <Button size="sm" variant="secondary" onClick={() => setFresh(null)}>I have saved them</Button>
        </div>
      )}

      {tokens !== null && tokens.length === 0 && !creating && !fresh && (
        <EmptyState
          title="No Home Assistant connection yet"
          description="Create a token, paste it into the Orbitly integration in Home Assistant, and your family shows up as device trackers."
          action={<Button onClick={() => setCreating(true)}>Create a token</Button>}
        />
      )}

      {creating && (
        <form className="wb-ha-form" onSubmit={create}>
          <label className="wb-field" htmlFor="wb-ha-name">
            <span className="wb-label">Name</span>
            <input id="wb-ha-name" className="wb-input" value={name} maxLength={60}
              onChange={(e) => setName(e.target.value)} required disabled={Boolean(busy)} />
          </label>
          <fieldset className="wb-ha-fieldset">
            <legend className="wb-label">Circles Home Assistant may see</legend>
            {circles.length === 0 && <p className="wb-help">You are not in any circle yet.</p>}
            {circles.map((c) => (
              <label key={c.id} className="wb-ha-check">
                <input type="checkbox" checked={picked.has(c.id)} onChange={() => setPicked(toggle(picked, c.id))} />
                <span>{circleLabel(c)}</span>
              </label>
            ))}
            {circles.some((c) => c.e2ee_mode === 'private') && (
              <p className="wb-help">Private circles are listed but never reveal positions to Home Assistant.</p>
            )}
          </fieldset>
          <fieldset className="wb-ha-fieldset">
            <legend className="wb-label">What it may read</legend>
            {HA_SCOPE_INFO.map((s) => (
              <label key={s.id} className="wb-ha-check">
                <input type="checkbox" checked={scopes.has(s.id) || (s.id === 'presence' && scopes.has('location'))}
                  disabled={s.id === 'presence' && scopes.has('location')}
                  onChange={() => setScopes(toggle(scopes, s.id))} />
                <span><strong>{s.label}</strong> <span className="wb-help">{s.help}</span></span>
              </label>
            ))}
          </fieldset>
          <div className="wb-settings-form-actions">
            <Button type="submit" loading={busy === 'create'} disabled={Boolean(busy) || picked.size === 0 || scopes.size === 0}>
              Create token
            </Button>
            <Button type="button" variant="ghost" onClick={() => setCreating(false)} disabled={Boolean(busy)}>Cancel</Button>
          </div>
        </form>
      )}

      {tokens && tokens.length > 0 && (
        <ul className="wb-ha-list">
          {tokens.map((t) => (
            <TokenRow key={t.id} t={t} open={openId === t.id} isPlatformAdmin={isPlatformAdmin}
              circleName={circleName} busy={busy === t.id}
              onToggle={() => setOpenId(openId === t.id ? null : t.id)}
              onRevoke={() => void revoke(t)}
              onChanged={(next, note) => {
                setTokens((cur) => (cur ?? []).map((x) => (x.id === next.id ? next : x)))
                if (next.webhook_secret) setFresh({ ...next, token: undefined })
                if (note) setMsg({ tone: 'success', text: note })
              }}
              onError={(text) => setMsg({ tone: 'error', text })} />
          ))}
        </ul>
      )}

      {tokens && tokens.length > 0 && !creating && (
        <div className="wb-settings-form-actions">
          <Button variant="secondary" onClick={() => setCreating(true)}>Add another token</Button>
        </div>
      )}
      {msg && (
        <p className={`wb-profile-message wb-profile-message-${msg.tone}`} role={msg.tone === 'error' ? 'alert' : 'status'}>
          {msg.text}
        </p>
      )}
    </Card>
  )
}

interface RowProps {
  t: HaToken
  open: boolean
  isPlatformAdmin: boolean
  busy: boolean
  circleName: (id: string) => string
  onToggle: () => void
  onRevoke: () => void
  onChanged: (t: HaToken, note?: string) => void
  onError: (text: string) => void
}

function TokenRow({ t, open, isPlatformAdmin, busy, circleName, onToggle, onRevoke, onChanged, onError }: RowProps) {
  const [url, setUrl] = React.useState('')
  const [allowPrivate, setAllowPrivate] = React.useState(t.webhook_allow_private)
  const [events, setEvents] = React.useState<Set<HaEventKind>>(new Set(t.webhook_events))
  const [work, setWork] = React.useState<string | null>(null)
  const hasEvents = t.scopes.includes('events')

  const save = async (e: React.FormEvent) => {
    e.preventDefault()
    setWork('save')
    try {
      const input: Parameters<typeof updateHaToken>[1] = { webhook_events: [...events] }
      if (url.trim() !== '') input.webhook_url = url.trim()
      if (isPlatformAdmin && allowPrivate !== t.webhook_allow_private) input.webhook_allow_private = allowPrivate
      const next = await updateHaToken(t.id, input)
      setUrl('')
      onChanged(next, 'Webhook settings saved.')
    } catch (err) {
      onError(errText(err, 'Could not save the webhook.'))
    } finally {
      setWork(null)
    }
  }
  const remove = async () => {
    if (!window.confirm('Remove the webhook? Home Assistant stops receiving events.')) return
    setWork('remove')
    try {
      onChanged(await updateHaToken(t.id, { webhook_url: '' }), 'Webhook removed.')
    } catch (err) {
      onError(errText(err, 'Could not remove the webhook.'))
    } finally {
      setWork(null)
    }
  }
  const test = async () => {
    setWork('test')
    try {
      const r = await testHaWebhook(t.id)
      onChanged(
        { ...t, last_delivery_ok: r.ok, last_delivery_code: r.status_code || null, last_delivery_error: r.error, last_delivery_event: 'test', last_delivery_at: new Date().toISOString() },
        r.ok ? 'Test event delivered.' : `Test failed: ${r.error || 'unknown error'}${r.status_code ? ` (HTTP ${r.status_code})` : ''}`
      )
    } catch (err) {
      onError(errText(err, 'Could not send the test event.'))
    } finally {
      setWork(null)
    }
  }
  const rotate = async () => {
    if (!window.confirm('Generate a new signing secret? Update Home Assistant afterwards.')) return
    setWork('rotate')
    try {
      onChanged(await updateHaToken(t.id, { rotate_webhook_secret: true }), 'New signing secret generated.')
    } catch (err) {
      onError(errText(err, 'Could not rotate the secret.'))
    } finally {
      setWork(null)
    }
  }

  const delivery = t.last_delivery_at
    ? t.last_delivery_ok
      ? { tone: 'green' as const, text: `Delivered ${ago(t.last_delivery_at)}` }
      : { tone: 'red' as const, text: `Failed ${ago(t.last_delivery_at)}: ${t.last_delivery_error || 'error'}` }
    : null

  return (
    <li className="wb-ha-row">
      <div className="wb-ha-row-head">
        <div className="wb-ha-row-main">
          <strong>{t.name}</strong>
          <span className="wb-help">
            ofha_…{t.token_hint.replace('…', '')} · last used {ago(t.last_used_at)} · {t.circle_ids.map(circleName).join(', ')}
          </span>
          <span className="wb-ha-badges">
            {t.scopes.map((s) => <Badge key={s} tone={s === 'location' ? 'orange' : 'neutral'}>{s}</Badge>)}
            {t.webhook_configured && <Badge tone={delivery ? delivery.tone : 'grey'} dot>{delivery ? delivery.text : 'Webhook set, nothing sent yet'}</Badge>}
          </span>
        </div>
        <div className="wb-ha-row-actions">
          <Button size="sm" variant="secondary" onClick={onToggle} aria-expanded={open}>{open ? 'Close' : 'Webhook'}</Button>
          <Button size="sm" variant="danger" onClick={onRevoke} loading={busy}>Revoke</Button>
        </div>
      </div>
      {open && (
        <form className="wb-ha-webhook" onSubmit={save}>
          {!hasEvents ? (
            <p className="wb-help">This token has no Events scope, so it cannot receive webhooks. Create a new token with Events.</p>
          ) : (
            <>
              <label className="wb-field" htmlFor={`wb-ha-url-${t.id}`}>
                <span className="wb-label">Webhook URL</span>
                <input id={`wb-ha-url-${t.id}`} className="wb-input" type="url" value={url}
                  onChange={(e) => setUrl(e.target.value)} autoComplete="off" spellCheck={false}
                  placeholder={t.webhook_configured ? `${t.webhook_url_masked} (leave blank to keep)` : 'http://homeassistant.local:8123/api/webhook/<id>'} />
                <span className="wb-help">
                  The Orbitly integration shows this URL when you add it. Requests are signed (HMAC-SHA256) and retried with backoff.
                </span>
              </label>
              <label className="wb-ha-check">
                <input type="checkbox" checked={allowPrivate} disabled={!isPlatformAdmin}
                  onChange={(e) => setAllowPrivate(e.target.checked)} />
                <span>
                  Home Assistant is on my local network
                  <span className="wb-help"> {isPlatformAdmin
                    ? 'Allows private addresses such as 192.168.x.x. Loopback and link-local (cloud metadata) are always refused.'
                    : 'A server administrator must enable this. Public https addresses (for example Nabu Casa) work without it.'}</span>
                </span>
              </label>
              <fieldset className="wb-ha-fieldset">
                <legend className="wb-label">Events to send</legend>
                <div className="wb-ha-events">
                  {HA_EVENT_INFO.map((ev) => (
                    <label key={ev.id} className="wb-ha-check">
                      <input type="checkbox" checked={events.has(ev.id)}
                        onChange={() => setEvents((cur) => { const n = new Set(cur); if (n.has(ev.id)) n.delete(ev.id); else n.add(ev.id); return n })} />
                      <span>{ev.label}</span>
                    </label>
                  ))}
                </div>
              </fieldset>
              <div className="wb-settings-form-actions">
                <Button type="submit" size="sm" loading={work === 'save'} disabled={work !== null}>Save webhook</Button>
                <Button type="button" size="sm" variant="secondary" loading={work === 'test'}
                  disabled={work !== null || !t.webhook_configured} onClick={() => void test()}>Send test event</Button>
                <Button type="button" size="sm" variant="ghost" loading={work === 'remove'}
                  disabled={work !== null || !t.webhook_configured} onClick={() => void remove()}>Remove webhook</Button>
                <Button type="button" size="sm" variant="ghost" loading={work === 'rotate'}
                  disabled={work !== null} onClick={() => void rotate()}>New signing secret</Button>
              </div>
            </>
          )}
        </form>
      )}
    </li>
  )
}
