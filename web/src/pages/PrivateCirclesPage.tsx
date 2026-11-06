// Private circles: a read-only viewer for end-to-end encrypted circles.
//
// This browser registers its own key pair (generated here, the private key never
// leaves the browser), a phone of the signed-in person approves it, and from then
// on the browser decrypts the circle's ciphertext locally. The server only ever
// sees public keys, wrapped keys and ciphertext. See docs/design/E2EE.md
// ("Phase 3: web viewer") for what this does and does not protect against.

import React from 'react'
import { e2eeHttp, getProfile } from '../lib/api'
import { getAccessToken } from '../lib/auth'
import { useMe } from '../lib/me'
import { useAsync } from '../lib/useAsync'
import { Badge, Button, Card, CopyButton, EmptyState, Mono, Spinner } from '../components/primitives'
import MapView from '../map/MapView'
import { deriveMember } from '../map/status'
import type { Group, Member } from '../map/types'
import { ViewerController, type CircleConn } from '../e2ee/controller'
import { digitGroups, fingerprint, shortFingerprint } from '../e2ee/core'
import type { CustodyMode } from '../e2ee/keystore'
import type { Point } from '../e2ee/viewer'
import './pages.css'
import './PrivateCirclesPage.css'

interface CircleRow {
  id: string
  name: string
  e2ee_mode?: string
  e2ee_epoch?: number
}

const MEMBER_COLORS = ['#0a84ff', '#e91e8c', '#34c759', '#ff9500', '#af52de', '#00c7be', '#ff2d55', '#5ac8fa']

/** SHA-256 of the scripts and styles this page was loaded from, for comparing with a published build hash. */
async function bundleFingerprint(): Promise<string> {
  const urls = [...document.querySelectorAll<HTMLScriptElement>('script[src]')].map((s) => s.src)
  urls.push(...[...document.querySelectorAll<HTMLLinkElement>('link[rel=stylesheet]')].map((l) => l.href))
  const parts: string[] = []
  for (const u of urls.sort()) {
    try {
      const buf = await (await fetch(u, { cache: 'force-cache' })).arrayBuffer()
      const h = new Uint8Array(await crypto.subtle.digest('SHA-256', buf))
      parts.push([...h].map((b) => b.toString(16).padStart(2, '0')).join('') + '  ' + new URL(u).pathname)
    } catch {
      parts.push('unreadable  ' + u)
    }
  }
  return parts.join('\n')
}

function useController(): { ctl: ViewerController | null; tick: number } {
  const [ctl, setCtl] = React.useState<ViewerController | null>(null)
  const [tick, setTick] = React.useState(0)
  React.useEffect(() => {
    let alive = true
    let c: ViewerController | null = null
    getProfile().then(async (p) => {
      if (!alive) return
      c = new ViewerController(e2eeHttp, p.id, undefined, getAccessToken)
      c.subscribe(() => setTick((t) => t + 1))
      await c.init()
      if (alive) setCtl(c)
    })
    return () => {
      alive = false
      c?.dispose()
    }
  }, [])
  return { ctl, tick }
}

export function PrivateCirclesPage() {
  const { ctl, tick } = useController()
  const { isPlatformAdmin } = useMe()
  const circles = useAsync(() => e2eeHttp.get<CircleRow[]>('/circles'), [])
  const [selected, setSelected] = React.useState<string | null>(null)
  void tick

  if (!ctl) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading…
        </div>
      </div>
    )
  }
  const priv = (circles.data ?? []).filter((c) => c.e2ee_mode === 'private')

  return (
    <div className="wb-page">
      <div style={{ marginRight: 'auto' }}>
        <h1 className="wb-page-title">Private circles</h1>
        <p className="wb-page-subtitle">
          End-to-end encrypted circles. The server holds only ciphertext; this browser decrypts it with a key that was
          approved by one of your phones.
        </p>
      </div>
      <TrustCard isPlatformAdmin={isPlatformAdmin} />
      <ViewerSetup ctl={ctl} />
      {ctl.unlocked && ctl.meta?.registered ? (
        <>
          {circles.loading ? (
            <Spinner />
          ) : priv.length === 0 ? (
            <Card>
              <EmptyState
                title="You are not in a Private circle"
                description={
                  isPlatformAdmin
                    ? 'As a platform admin you see a Private circle only when your own account is a member and your own browser key is approved. The server cannot grant that.'
                    : 'Switch a circle to Private in the phone app (Settings, Security, Encryption keys) first.'
                }
              />
            </Card>
          ) : (
            <Card>
              <h2 className="wb-sec-title">Circles</h2>
              <div className="wb-pc-row">
                {priv.map((c) => {
                  const conn = ctl.conns.get(c.id)
                  return (
                    <Button
                      key={c.id}
                      variant={selected === c.id ? 'primary' : 'secondary'}
                      onClick={() => {
                        setSelected(c.id)
                        if (!conn) void ctl.connect(c.id, c.name)
                      }}
                    >
                      {c.name} {conn ? `· ${phaseLabel(conn)}` : ''}
                    </Button>
                  )
                })}
              </div>
            </Card>
          )}
          {selected && ctl.conns.get(selected) && <CircleView ctl={ctl} conn={ctl.conns.get(selected)!} />}
        </>
      ) : null}
    </div>
  )
}

function phaseLabel(c: CircleConn): string {
  switch (c.phase) {
    case 'live':
      return 'live'
    case 'syncing':
      return 'syncing'
    case 'waiting-for-key':
      return 'waiting for a phone to share the key'
    case 'revoked':
      return 'revoked'
    case 'error':
      return 'error'
    default:
      return 'idle'
  }
}

function TrustCard({ isPlatformAdmin }: { isPlatformAdmin: boolean }) {
  const [fp, setFp] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  return (
    <Card>
      <h2 className="wb-sec-title">What you are trusting</h2>
      <ul className="wb-pc-list">
        <li>
          The private key is created in this browser and is never sent anywhere. The server cannot decrypt anything and cannot
          approve this viewer.
        </li>
        <li>
          <strong>The page code itself decides what happens to the decrypted data.</strong> Whoever can change the JavaScript this
          server sends you (the operator, or an attacker who controls the server or its TLS) could ship a version that reads your
          positions. End-to-end encryption protects against a stolen database and a curious operator who does not tamper with the
          web app; it does not protect against a malicious web app. For the strongest guarantee use the phone app.
        </li>
        <li>
          A browser extension or a script injected into this page can also read what is shown. Use a clean browser profile; do not
          use this on a shared computer unless you choose the passphrase or session mode.
        </li>
        {isPlatformAdmin && (
          <li>
            Platform admin: the admin location rules are unchanged. You see a Private circle only if your own account is a member
            and your own browser key was approved by your own phone. The server cannot grant it.
          </li>
        )}
      </ul>
      <Button
        size="sm"
        variant="secondary"
        loading={busy}
        onClick={async () => {
          setBusy(true)
          setFp(await bundleFingerprint())
          setBusy(false)
        }}
      >
        Show hashes of the code running here
      </Button>
      {fp && (
        <>
          <pre className="wb-pc-pre">{fp}</pre>
          <p className="wb-hint">
            Compare with <code>sha256sum</code> of the same files from the release you trust. These hashes are computed by this
            same page, so they only help if you check them against a source the server does not control.
          </p>
        </>
      )}
    </Card>
  )
}

function ViewerSetup({ ctl }: { ctl: ViewerController }) {
  const [name, setName] = React.useState(`Browser on ${navigator.platform || 'computer'}`.slice(0, 40))
  const [mode, setMode] = React.useState<CustodyMode>(ViewerController.supportsDeviceMode() ? 'device' : 'passphrase')
  const [pass, setPass] = React.useState('')
  const [request, setRequest] = React.useState<string | null>(null)
  const [approval, setApproval] = React.useState('')
  const [err, setErr] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  const meta = ctl.meta

  const run = async (f: () => Promise<void>) => {
    setBusy(true)
    setErr(null)
    try {
      await f()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  if (!meta) {
    return (
      <Card>
        <h2 className="wb-sec-title">1. Create a viewer key in this browser</h2>
        <label className="wb-field">
          Name shown on your phone
          <input value={name} maxLength={40} onChange={(e) => setName(e.target.value)} />
        </label>
        <fieldset className="wb-pc-modes">
          <label>
            <input type="radio" checked={mode === 'device'} disabled={!ViewerController.supportsDeviceMode()} onChange={() => setMode('device')} />
            <span>
              <strong>This browser (recommended)</strong>: non-extractable key, kept in this browser profile. Needs a recent
              browser. Anyone with access to your computer account can use it.
            </span>
          </label>
          <label>
            <input type="radio" checked={mode === 'passphrase'} onChange={() => setMode('passphrase')} />
            <span>
              <strong>Passphrase</strong>: the key is stored encrypted (Argon2id) and you type the passphrase once per visit.
            </span>
          </label>
          <label>
            <input type="radio" checked={mode === 'session'} onChange={() => setMode('session')} />
            <span>
              <strong>This visit only</strong>: nothing is stored; the viewer disappears when you close the tab. Remember to
              revoke it afterwards.
            </span>
          </label>
        </fieldset>
        {mode === 'passphrase' && (
          <label className="wb-field">
            Passphrase (8+ characters)
            <input type="password" autoComplete="new-password" value={pass} onChange={(e) => setPass(e.target.value)} />
          </label>
        )}
        <Button loading={busy} onClick={() => run(async () => setRequest(await ctl.create(name.trim() || 'Browser', mode, pass)))}>
          Create key
        </Button>
        {err && <p className="wb-error">{err}</p>}
      </Card>
    )
  }

  if (ctl.needsPassphrase()) {
    return (
      <Card>
        <h2 className="wb-sec-title">Unlock the viewer key</h2>
        <label className="wb-field">
          Passphrase
          <input type="password" autoComplete="current-password" value={pass} onChange={(e) => setPass(e.target.value)} />
        </label>
        <Button loading={busy} onClick={() => run(() => ctl.unlock(pass))}>
          Unlock
        </Button>
        <Button variant="danger" size="sm" onClick={() => run(() => ctl.forget())}>
          Forget this key
        </Button>
        {err && <p className="wb-error">{err}</p>}
      </Card>
    )
  }

  if (!meta.registered) {
    const u = ctl.unlocked
    const fp = u ? fingerprint(u.ops.edPub, u.ops.xPub) : null
    return (
      <Card>
        <h2 className="wb-sec-title">2. Approve this browser on your phone</h2>
        {!u ? (
          <>
            <p>This browser has a viewer key but it is not unlocked (session keys are lost on reload).</p>
            <Button variant="danger" size="sm" onClick={() => run(() => ctl.forget())}>
              Start over
            </Button>
          </>
        ) : (
          <>
            <ol className="wb-pc-list">
              <li>
                On your phone open the Private circle, <em>Approve a viewer or bridge</em>, and paste this request code.
              </li>
              <li>Compare the number below with the one the phone shows, then approve.</li>
              <li>Paste the approval code the phone gives you here.</li>
            </ol>
            <div className="wb-pc-code">
              <Mono truncate="end" max={64}>{request ?? '…'}</Mono>
              <CopyButton value={request ?? ''} label="Copy request code" />
              {!request && (
                <Button size="sm" variant="secondary" onClick={() => run(async () => setRequest(await ctl.requestCode()))}>
                  Show request code
                </Button>
              )}
            </div>
            {fp && (
              <p>
                Fingerprint <strong>{shortFingerprint(fp)}</strong>
                <br />
                <code>{digitGroups(fp)}</code>
              </p>
            )}
            <label className="wb-field">
              Approval code from the phone
              <textarea rows={3} value={approval} onChange={(e) => setApproval(e.target.value)} />
            </label>
            <Button loading={busy} disabled={!approval.trim()} onClick={() => run(() => ctl.register(approval))}>
              Register viewer
            </Button>
            <Button variant="danger" size="sm" onClick={() => run(() => ctl.forget())}>
              Cancel and delete key
            </Button>
          </>
        )}
        {err && <p className="wb-error">{err}</p>}
      </Card>
    )
  }

  const u = ctl.unlocked
  const fp = u ? fingerprint(u.ops.edPub, u.ops.xPub) : null
  return (
    <Card>
      <h2 className="wb-sec-title">
        This viewer <Badge tone="green">approved by your phone</Badge>
      </h2>
      <p>
        {meta.name} · key kept: {meta.mode === 'device' ? 'in this browser (non-extractable)' : meta.mode === 'passphrase' ? 'passphrase protected' : 'this visit only'}
      </p>
      {fp && (
        <p>
          Fingerprint <strong>{shortFingerprint(fp)}</strong> · <code>{digitGroups(fp)}</code>
        </p>
      )}
      <Button
        variant="danger"
        size="sm"
        loading={busy}
        onClick={() => {
          if (window.confirm('Revoke this viewer? It stops receiving new data after the next key rotation on your phone, and the key is deleted from this browser.')) {
            void run(() => ctl.revoke())
          }
        }}
      >
        Revoke this viewer
      </Button>
      {err && <p className="wb-error">{err}</p>}
    </Card>
  )
}

function CircleView({ ctl, conn }: { ctl: ViewerController; conn: CircleConn }) {
  const [who, setWho] = React.useState<string | null>(null)
  const now = Date.now()
  const members: Member[] = React.useMemo(() => {
    const st = conn.state
    if (!st) return []
    return st.members.map((m, i) => {
      const p = conn.book.last.get(m.user_id)
      return deriveMember(
        {
          id: m.user_id,
          name: m.name,
          lat: p?.lat ?? null,
          lon: p?.lon ?? null,
          ts: p?.ts ?? null,
          battery_pct: p?.bat ?? null,
          speed_mps: p?.spd ?? null,
          motion_state: p?.mo ?? null,
          accuracy_meters: p?.acc ?? null,
        },
        conn.circleId,
        conn.name,
        '#8fd400',
        MEMBER_COLORS[i % MEMBER_COLORS.length]!,
        now,
      )
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conn.state, conn.lastUpdate, conn.circleId, conn.name])
  const groups: Group[] = [{ id: conn.circleId, name: conn.name }]

  return (
    <Card>
      <h2 className="wb-sec-title">
        {conn.name} <Badge tone="green">Decrypted in your browser</Badge> <Badge tone="neutral">{phaseLabel(conn)}</Badge>
      </h2>
      {conn.error && <p className="wb-error">{conn.error}</p>}
      {conn.phase === 'waiting-for-key' && (
        <p>
          Waiting for one of your phones to share this circle’s key with this viewer. Open the circle on your phone
          (Settings, Security, Encryption keys); this page keeps checking.
        </p>
      )}
      {conn.phase === 'revoked' && <p>This viewer is no longer approved for the circle. Revoke it and set up a new one if needed.</p>}
      <p className="wb-hint">
        Epoch {conn.state?.epoch ?? '?'} · keys held for epochs {conn.report?.heldEpochs.join(', ') || 'none'} · {conn.counts.opened}{' '}
        items opened, {conn.counts.dropped} rejected, {conn.counts.deferred} waiting. Positions exist only in this page’s memory.
      </p>
      {conn.report && conn.report.memberTrustedEpochs.length > 0 && (
        <p className="wb-hint">
          The key for epoch {conn.report.memberTrustedEpochs.join(', ')} came straight from another member, not from one of your own phones.
          Its origin rests on first-use trust in that member’s key, which this page cannot verify. Open the circle on your phone and compare safety numbers.
        </p>
      )}
      {conn.report && conn.report.rejectedWraps > 0 && (
        <p className="wb-error">{conn.report.rejectedWraps} wrapped key(s) failed verification and were ignored.</p>
      )}
      {members.length > 0 && (
        <div className="wb-pc-map">
          <MapView groups={groups} members={members} initialZoom={12} />
        </div>
      )}
      <h3 className="wb-sec-title">Members</h3>
      <table className="wb-table">
        <thead>
          <tr>
            <th>Member</th>
            <th>Last known</th>
            <th>Battery</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {conn.state?.members.map((m) => {
            const p = conn.book.last.get(m.user_id)
            return (
              <tr key={m.user_id}>
                <td>{m.name}</td>
                <td>{p ? `${new Date(p.ts).toLocaleString()} · ${p.lat.toFixed(5)}, ${p.lon.toFixed(5)}` : 'nothing decrypted yet'}</td>
                <td>{p?.bat != null ? `${Math.round(p.bat)}%` : '—'}</td>
                <td>
                  <Button size="sm" variant="secondary" disabled={!p} onClick={() => setWho(who === m.user_id ? null : m.user_id)}>
                    History
                  </Button>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {who && <Trail points={conn.book.trail(who)} />}
      {conn.book.events.length > 0 && (
        <>
          <h3 className="wb-sec-title">Recent events</h3>
          <ul className="wb-pc-list">
            {conn.book.events
              .slice(-10)
              .reverse()
              .map((e, i) => (
                <li key={i}>
                  {new Date(e.ts).toLocaleTimeString()} · {e.name} {e.kind === 'place' ? `${e.action === 'exit' ? 'left' : 'arrived at'} ${e.place ?? 'a place'}` : e.kind}
                </li>
              ))}
          </ul>
        </>
      )}
      <Button size="sm" variant="secondary" onClick={() => void ctl.connect(conn.circleId, conn.name)}>
        Refresh now
      </Button>
    </Card>
  )
}

/** A dependency-free trail sketch (no map tiles are requested for decrypted positions). */
function Trail({ points }: { points: Point[] }) {
  if (points.length === 0) return null
  const lats = points.map((p) => p.lat)
  const lons = points.map((p) => p.lon)
  const minLat = Math.min(...lats), maxLat = Math.max(...lats)
  const minLon = Math.min(...lons), maxLon = Math.max(...lons)
  const w = 520, h = 220, pad = 12
  const sx = (lon: number) => pad + (maxLon === minLon ? 0.5 : (lon - minLon) / (maxLon - minLon)) * (w - 2 * pad)
  const sy = (lat: number) => h - pad - (maxLat === minLat ? 0.5 : (lat - minLat) / (maxLat - minLat)) * (h - 2 * pad)
  const path = points.map((p, i) => `${i ? 'L' : 'M'}${sx(p.lon).toFixed(1)},${sy(p.lat).toFixed(1)}`).join(' ')
  const last = points[points.length - 1]!
  return (
    <div>
      <svg viewBox={`0 0 ${w} ${h}`} className="wb-pc-trail" role="img" aria-label="Decrypted trail sketch">
        <path d={path} fill="none" stroke="currentColor" strokeWidth="2" />
        <circle cx={sx(last.lon)} cy={sy(last.lat)} r="5" fill="currentColor" />
      </svg>
      <p className="wb-hint">
        {points.length} points from {new Date(points[0]!.ts).toLocaleString()} to {new Date(last.ts).toLocaleString()} (sketch, north up,
        not to scale).
      </p>
    </div>
  )
}
