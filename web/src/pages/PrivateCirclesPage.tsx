// Private circles: a read-only viewer for end-to-end encrypted circles.
//
// This browser registers its own key pair (generated here, the private key never
// leaves the browser), a phone of the signed-in person approves it, and from then
// on the browser decrypts the circle's ciphertext locally. The server only ever
// sees public keys, wrapped keys and ciphertext. See docs/design/E2EE.md
// ("Phase 3: web viewer") for what this does and does not protect against.

import { ServerProcessingPanel } from './ServerProcessingPanel'
import React from 'react'
import { e2eeHttp } from '../lib/api'
import { getEmail } from '../lib/auth'
import { useMe } from '../lib/me'
import { useViewerController } from '../lib/privateViewer'
import { useAsync } from '../lib/useAsync'
import { Badge, Button, Card, CopyButton, EmptyState, ErrorState, Spinner } from '../components/primitives'
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

export function PrivateCirclesPage() {
  const { ctl, tick } = useViewerController()
  const { isPlatformAdmin } = useMe()
  const circles = useAsync(() => e2eeHttp.get<CircleRow[]>('/circles'), [])
  const [selected, setSelected] = React.useState<string | null>(null)
  void tick

  if (!ctl) {
    return (
      <div className="wb-page wb-pc-page">
        <div className="wb-page-loading">
          <Spinner /> Loading private circles…
        </div>
      </div>
    )
  }
  const priv = (circles.data ?? []).filter((c) => c.e2ee_mode === 'private')

  return (
    <div className="wb-page wb-pc-page">
      <div className="wb-page-header">
        <div style={{ marginRight: 'auto' }}>
          <h1 className="wb-page-title">Private circles</h1>
          <p className="wb-page-subtitle">
            End-to-end encrypted circles. The server holds only ciphertext; this browser decrypts it with a key that was
            approved by one of your phones.
          </p>
        </div>
      </div>
      {isPlatformAdmin && <ServerProcessingPanel />}
      <TrustCard isPlatformAdmin={isPlatformAdmin} defaultOpen={!ctl.meta && !ctl.account.status?.exists} />
      <AccountAccess ctl={ctl} />
      {showLocalSetup(ctl) ? (
        <ViewerSetup ctl={ctl} />
      ) : (
        <details className="wb-card wb-pc-trust">
          <summary>
            <span className="wb-pc-trust-icon"><BrowserIcon /></span>
            <span className="wb-pc-trust-title">Or keep a key only in this browser</span>
            <span className="wb-pc-trust-hint">The older way: a key tied to this computer</span>
            <span className="wb-pc-chevron" aria-hidden="true" />
          </summary>
          <div className="wb-pc-trust-body">
            <ViewerSetup ctl={ctl} />
          </div>
        </details>
      )}
      {ctl.unlocked && ctl.meta?.registered ? (
        <>
          {circles.loading ? (
            <div className="wb-page-loading">
              <Spinner /> Loading circles…
            </div>
          ) : circles.error ? (
            <ErrorState title="Couldn’t load circles" description={circles.error.message} onRetry={circles.refetch} />
          ) : priv.length === 0 ? (
            <Card>
              <EmptyState
                icon={<LockIcon />}
                title="You are not in a Private circle"
                description={
                  isPlatformAdmin
                    ? 'As a platform admin you see a Private circle only when your own account is a member and your own browser key is approved. The server cannot grant that.'
                    : 'Switch a circle to Private in the phone app (Settings, Security, Encryption keys) first.'
                }
              />
            </Card>
          ) : (
            <section className="wb-pc-section" aria-labelledby="wb-pc-circles">
              <h2 id="wb-pc-circles" className="wb-pc-h2">Your private circles</h2>
              <div className="wb-pc-circles">
                {priv.map((c) => {
                  const conn = ctl.conns.get(c.id)
                  return (
                    <button
                      key={c.id}
                      type="button"
                      className={`wb-pc-circle${selected === c.id ? ' is-selected' : ''}`}
                      aria-pressed={selected === c.id}
                      onClick={() => {
                        setSelected(c.id)
                        if (!conn) void ctl.connect(c.id, c.name)
                      }}
                    >
                      <span className="wb-pc-circle-icon"><LockIcon /></span>
                      <span className="wb-pc-circle-name">{c.name}</span>
                      <span className="wb-pc-circle-phase">{conn ? phaseLabel(conn) : 'tap to open'}</span>
                    </button>
                  )
                })}
              </div>
            </section>
          )}
          {selected && ctl.conns.get(selected) && <CircleView ctl={ctl} conn={ctl.conns.get(selected)!} />}
        </>
      ) : null}
    </div>
  )
}

function LockIcon() {
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="4" y="11" width="16" height="10" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </svg>
  )
}
function BrowserIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" />
    </svg>
  )
}
function KeyIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <circle cx="8" cy="15" r="4" /><path d="M11 12l9-9M16 7l3 3" />
    </svg>
  )
}
function ClockIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
    </svg>
  )
}
function CheckIcon() {
  return (
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12l5 5 9-10" />
    </svg>
  )
}

/** Fingerprint shown as a short code plus grouped monospace digits, with copy. */
function FingerprintBox({ fp }: { fp: Uint8Array }) {
  return (
    <div className="wb-pc-fp">
      <div className="wb-pc-fp-head">
        <span className="wb-pc-fp-label">Fingerprint</span>
        <strong className="wb-pc-fp-short">{shortFingerprint(fp)}</strong>
        <CopyButton value={digitGroups(fp)} label="Copy fingerprint" />
      </div>
      <code className="wb-pc-fp-digits">{digitGroups(fp)}</code>
    </div>
  )
}

const STEPS = ['Create key', 'Send request code', 'Paste approval', 'Connected']

function Stepper({ current }: { current: number }) {
  return (
    <ol className="wb-pc-steps" aria-label="Pairing progress">
      {STEPS.map((label, i) => {
        const n = i + 1
        const state = n < current ? 'done' : n === current ? 'current' : 'todo'
        return (
          <li key={label} className={`wb-pc-step is-${state}`} aria-current={state === 'current' ? 'step' : undefined}>
            <span className="wb-pc-step-dot">{state === 'done' ? <CheckIcon /> : n}</span>
            <span className="wb-pc-step-label">{label}</span>
          </li>
        )
      })}
    </ol>
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

function TrustCard({ isPlatformAdmin, defaultOpen }: { isPlatformAdmin: boolean; defaultOpen: boolean }) {
  const [fp, setFp] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  return (
    <details className="wb-card wb-pc-trust" open={defaultOpen}>
      <summary>
        <span className="wb-pc-trust-icon"><LockIcon /></span>
        <span className="wb-pc-trust-title">What you are trusting</span>
        <span className="wb-pc-trust-hint">Read once before you create a key</span>
        <span className="wb-pc-chevron" aria-hidden="true" />
      </summary>
      <div className="wb-pc-trust-body">
        <div className="wb-pc-warn" role="note">
          <strong>The page code itself decides what happens to the decrypted data.</strong> Whoever can change the JavaScript
          this server sends you (the operator, or an attacker who controls the server or its TLS) could ship a version that
          reads your positions. End-to-end encryption protects against a stolen database and a curious operator who does not
          tamper with the web app; it does not protect against a malicious web app. For the strongest guarantee use the phone
          app.
        </div>
        <ul className="wb-pc-bullets">
          <li>
            <strong>Key stays here</strong> (a key for this browser only). The private key is created in this browser and is
            never sent anywhere. The server cannot decrypt anything and cannot approve this viewer.
          </li>
          <li>
            <strong>Web access from any browser</strong> stores the key on the server, sealed with your vault passphrase,
            which never leaves the browser. The server cannot open it, but a weak passphrase can be guessed by someone who
            steals the database and the server&rsquo;s vault key file. Choose a long one.
          </li>
          <li>
            <strong>Extensions and injected scripts</strong> can also read what is shown. Use a clean browser profile; do not
            use this on a shared computer unless you choose the passphrase or session mode.
          </li>
          {isPlatformAdmin && (
            <li>
              <strong>Platform admin:</strong> the admin location rules are unchanged. You see a Private circle only if your own
              account is a member and your own browser key was approved by your own phone. The server cannot grant it.
            </li>
          )}
        </ul>
        <div>
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
        </div>
        {fp && (
          <>
            <pre className="wb-pc-pre">{fp}</pre>
            <p className="wb-hint">
              Compare with <code>sha256sum</code> of the same files from the release you trust. These hashes are computed by
              this same page, so they only help if you check them against a source the server does not control.
            </p>
          </>
        )}
      </div>
    </details>
  )
}

/** The local (this-browser) setup is shown directly unless web access from any browser is offered or in use. */
function showLocalSetup(ctl: ViewerController): boolean {
  if (ctl.accountMode) return true // pairing or connected card of the account key
  if (ctl.meta) return true // this browser already has its own key
  const st = ctl.account.status
  return !st || !st.available
}

const VAULT_REASON: Record<string, string> = {
  off_by_operator: 'Web access from any browser is switched off on this server (E2EE_VIEWER_VAULT=off).',
  off_in_settings: 'Web access from any browser is switched off in Settings, Security.',
  pepper_unavailable: 'Web access from any browser is unavailable: the server cannot read or create its vault key file. See the server log.',
}

function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}

function StepUpFields({ pw, setPw, totp, setTotp, id }: { pw: string; setPw: (v: string) => void; totp: string; setTotp: (v: string) => void; id: string }) {
  return (
    <div className="wb-pc-stepup">
      <label className="wb-field" htmlFor={`${id}-pw`}>
        <span className="wb-label">Account password</span>
        <input id={`${id}-pw`} className="wb-input" type="password" autoComplete="current-password" value={pw} onChange={(e) => setPw(e.target.value)} />
      </label>
      <label className="wb-field" htmlFor={`${id}-totp`}>
        <span className="wb-label">Two-factor code (if two-factor sign-in is on)</span>
        <input id={`${id}-totp`} className="wb-input" inputMode="numeric" autoComplete="one-time-code" value={totp} onChange={(e) => setTotp(e.target.value)} />
      </label>
    </div>
  )
}

/** Web access from any browser: set up, unlock, lock, change passphrase. */
function AccountAccess({ ctl }: { ctl: ViewerController }) {
  const st = ctl.account.status
  const [name, setName] = React.useState('Web access (any browser)')
  const [vp, setVp] = React.useState('')
  const [vp2, setVp2] = React.useState('')
  const [pw, setPw] = React.useState('')
  const [totp, setTotp] = React.useState('')
  const [err, setErr] = React.useState<string | null>(null)
  const [msg, setMsg] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  const [changing, setChanging] = React.useState(false)
  const avoid = [getEmail() ?? '', (getEmail() ?? '').split('@')[0] ?? ''].filter(Boolean)

  const run = async (f: () => Promise<void>, done?: string) => {
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      await f()
      setPw('')
      setTotp('')
      setVp('')
      setVp2('')
      if (done) setMsg(done)
    } catch (e) {
      setErr(errText(e))
    } finally {
      setBusy(false)
    }
  }
  if (!st) return null
  if (!st.available && !(ctl.accountMode && ctl.meta?.registered)) {
    const why = VAULT_REASON[st.reason]
    return why ? <p className="wb-hint">{why}</p> : null
  }

  // A new account key was approved and registered: seal it.
  if (ctl.accountMode && ctl.meta?.registered && !ctl.account.saved) {
    return (
      <Card className="wb-pc-card" data-testid="vault-choose">
        <h2 className="wb-pc-h2">Choose a vault passphrase</h2>
        <p className="wb-hint">
          This passphrase unlocks your private circles in any browser. It is never sent to the server; only the key sealed
          with it is stored there. Use at least 12 characters (a few unrelated words work well), not your account password.
          If you forget it, set web access up again from your phone.
        </p>
        <label className="wb-field" htmlFor="wb-vault-new">
          <span className="wb-label">Vault passphrase</span>
          <input id="wb-vault-new" className="wb-input" type="password" autoComplete="new-password" value={vp} onChange={(e) => setVp(e.target.value)} />
        </label>
        <label className="wb-field" htmlFor="wb-vault-new2">
          <span className="wb-label">Repeat the vault passphrase</span>
          <input id="wb-vault-new2" className="wb-input" type="password" autoComplete="new-password" value={vp2} onChange={(e) => setVp2(e.target.value)} />
        </label>
        <p className="wb-hint">Confirm it is you:</p>
        <StepUpFields id="wb-vault-save" pw={pw} setPw={setPw} totp={totp} setTotp={setTotp} />
        {err && <p className="wb-error" role="alert">{err}</p>}
        <div className="wb-pc-actions">
          <Button
            loading={busy}
            disabled={!vp || !pw}
            onClick={() =>
              run(async () => {
                if (vp !== vp2) throw new Error('the two vault passphrases differ')
                await ctl.saveAccountKey(vp, { password: pw, totpCode: totp }, avoid)
              }, 'Web access is set up. Next time, sign in from any browser and unlock here.')
            }
          >
            Save web access
          </Button>
        </div>
      </Card>
    )
  }

  // Unlocked with the account key.
  if (ctl.accountMode && ctl.meta?.registered) {
    return (
      <Card className="wb-pc-card" data-testid="vault-unlocked">
        <div className="wb-pc-connected">
          <div>
            <h2 className="wb-pc-h2">
              Web access from any browser <Badge tone="green" dot>Unlocked</Badge>
            </h2>
            <p className="wb-hint">
              The key is open in this tab only. It locks when you close or reload the tab, sign out, or after 30 minutes
              without activity.
            </p>
          </div>
          <div className="wb-pc-actions">
            <Button size="sm" variant="secondary" onClick={() => setChanging((v) => !v)}>
              Change vault passphrase
            </Button>
            <Button size="sm" onClick={() => ctl.lock()}>
              Lock
            </Button>
          </div>
        </div>
        {changing && (
          <div className="wb-pc-phase">
            <label className="wb-field" htmlFor="wb-vault-chg">
              <span className="wb-label">New vault passphrase</span>
              <input id="wb-vault-chg" className="wb-input" type="password" autoComplete="new-password" value={vp} onChange={(e) => setVp(e.target.value)} />
            </label>
            <label className="wb-field" htmlFor="wb-vault-chg2">
              <span className="wb-label">Repeat it</span>
              <input id="wb-vault-chg2" className="wb-input" type="password" autoComplete="new-password" value={vp2} onChange={(e) => setVp2(e.target.value)} />
            </label>
            <StepUpFields id="wb-vault-chg" pw={pw} setPw={setPw} totp={totp} setTotp={setTotp} />
            <p className="wb-hint">
              If you think the old passphrase leaked, do not just change it: revoke this key and set web access up again,
              because someone could have copied the old sealed key.
            </p>
            <Button
              loading={busy}
              disabled={!vp || !pw}
              onClick={() =>
                run(async () => {
                  if (vp !== vp2) throw new Error('the two vault passphrases differ')
                  await ctl.changeAccountPassphrase(vp, { password: pw, totpCode: totp }, avoid)
                  setChanging(false)
                }, 'Vault passphrase changed.')
              }
            >
              Save new passphrase
            </Button>
          </div>
        )}
        {err && <p className="wb-error" role="alert">{err}</p>}
        {msg && <p className="wb-help" role="status">{msg}</p>}
      </Card>
    )
  }
  if (ctl.accountMode) return null // pairing in progress: ViewerSetup shows the request code

  // Set up, stored on the server: unlock.
  if (st.exists) {
    const broken = st.pepper_changed || st.key_active === false
    return (
      <Card className="wb-pc-card" data-testid="vault-locked">
        <h2 className="wb-pc-h2">
          Private circles are locked <Badge tone="orange" dot>Web access from any browser</Badge>
        </h2>
        {broken ? (
          <>
            <p className="wb-error">
              {st.pepper_changed
                ? 'The server’s vault key file changed since web access was set up (for example a restore without it), so the stored key cannot be opened. Set web access up again.'
                : 'The web access key was revoked. Set web access up again.'}
            </p>
            <Button variant="danger" size="sm" loading={busy} onClick={() => run(() => ctl.deleteAccountVault())}>
              Remove the old setup
            </Button>
          </>
        ) : (
          <>
            <p className="wb-hint">Enter your vault passphrase. The server releases the sealed key only after you confirm your password.</p>
            <label className="wb-field" htmlFor="wb-vault-pass">
              <span className="wb-label">Vault passphrase</span>
              <input id="wb-vault-pass" className="wb-input" type="password" autoComplete="off" value={vp} onChange={(e) => setVp(e.target.value)} />
            </label>
            <StepUpFields id="wb-vault-unlock" pw={pw} setPw={setPw} totp={totp} setTotp={setTotp} />
            {err && <p className="wb-error" role="alert">{err}</p>}
            <div className="wb-pc-actions">
              <Button loading={busy} disabled={!vp || !pw} onClick={() => run(() => ctl.unlockAccount(vp, { password: pw, totpCode: totp }))}>
                Unlock
              </Button>
            </div>
            <p className="wb-hint">
              Unlocking takes a few seconds (the passphrase is deliberately slow to guess). Your phones are told when a
              browser unlocks for the first time. Forgot the vault passphrase? Revoke the web viewer on your phone, then
              set web access up again.
            </p>
          </>
        )}
      </Card>
    )
  }

  // Not set up yet.
  return (
    <Card className="wb-pc-card" data-testid="vault-setup">
      <h2 className="wb-pc-h2">
        Web access from any browser <Badge tone="green">Recommended</Badge>
      </h2>
      <p className="wb-hint">
        Approve one viewer key with your phone once. It is sealed with a vault passphrase that only you know and stored on
        the server, so you can sign in from any browser and unlock your private circles. The server cannot open it.
      </p>
      <ul className="wb-pc-bullets">
        <li>Unlocking needs your account password (and two-factor code), then the vault passphrase.</li>
        <li>A weak vault passphrase plus a stolen server database could expose the circles: choose a long one.</li>
        <li>The server’s vault key file (outside the database) is needed too: back it up separately from database backups.</li>
      </ul>
      <label className="wb-field" htmlFor="wb-vault-name">
        <span className="wb-label">Name shown on your phone</span>
        <input id="wb-vault-name" className="wb-input" value={name} maxLength={40} onChange={(e) => setName(e.target.value)} />
      </label>
      {err && <p className="wb-error" role="alert">{err}</p>}
      <div className="wb-pc-actions">
        <Button loading={busy} onClick={() => run(async () => void (await ctl.createAccountKey(name.trim() || 'Web access')))}>
          Set up web access
        </Button>
      </div>
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
    const deviceOk = ViewerController.supportsDeviceMode()
    const options: { id: CustodyMode; icon: React.ReactNode; title: string; badge?: string; body: string; trade: string }[] = [
      {
        id: 'device',
        icon: <BrowserIcon />,
        title: 'This browser',
        badge: 'Recommended',
        body: 'Non-extractable key, kept in this browser profile. Needs a recent browser.',
        trade: 'Anyone with access to your computer account can use it.',
      },
      {
        id: 'passphrase',
        icon: <KeyIcon />,
        title: 'Passphrase',
        body: 'The key is stored encrypted (Argon2id) and you type the passphrase once per visit.',
        trade: 'Safer on shared computers, a little more typing.',
      },
      {
        id: 'session',
        icon: <ClockIcon />,
        title: 'This visit only',
        body: 'Nothing is stored; the viewer disappears when you close the tab.',
        trade: 'Remember to revoke it afterwards.',
      },
    ]
    return (
      <Card className="wb-pc-card">
        <Stepper current={1} />
        <h2 className="wb-pc-h2">Create a viewer key in this browser</h2>
        <label className="wb-field" htmlFor="wb-pc-name">
          <span className="wb-label">Name shown on your phone</span>
          <input id="wb-pc-name" className="wb-input" value={name} maxLength={40} onChange={(e) => setName(e.target.value)} />
        </label>
        <fieldset className="wb-pc-modes">
          <legend className="wb-label">Where should the key live?</legend>
          <div className="wb-pc-mode-grid">
            {options.map((o) => {
              const disabled = o.id === 'device' && !deviceOk
              return (
                <label key={o.id} className={`wb-pc-mode${mode === o.id ? ' is-selected' : ''}${disabled ? ' is-disabled' : ''}`}>
                  <input type="radio" name="wb-pc-mode" checked={mode === o.id} disabled={disabled} onChange={() => setMode(o.id)} />
                  <span className="wb-pc-mode-icon">{o.icon}</span>
                  <span className="wb-pc-mode-title">
                    {o.title} {o.badge && <Badge tone="green">{o.badge}</Badge>}
                  </span>
                  <span className="wb-pc-mode-body">{o.body}</span>
                  <span className="wb-pc-mode-trade">{disabled ? 'Not supported by this browser.' : o.trade}</span>
                </label>
              )
            })}
          </div>
        </fieldset>
        {mode === 'passphrase' && (
          <label className="wb-field" htmlFor="wb-pc-pass">
            <span className="wb-label">Passphrase (8+ characters)</span>
            <input id="wb-pc-pass" className="wb-input" type="password" autoComplete="new-password" value={pass} onChange={(e) => setPass(e.target.value)} />
          </label>
        )}
        {err && <p className="wb-error" role="alert">{err}</p>}
        <div className="wb-pc-actions">
          <Button loading={busy} onClick={() => run(async () => setRequest(await ctl.create(name.trim() || 'Browser', mode, pass)))}>
            Create key
          </Button>
        </div>
      </Card>
    )
  }

  if (ctl.needsPassphrase()) {
    return (
      <Card className="wb-pc-card">
        <h2 className="wb-pc-h2">Unlock the viewer key</h2>
        <p className="wb-hint">This viewer key is passphrase protected. Enter it to read your private circles.</p>
        <label className="wb-field" htmlFor="wb-pc-unlock">
          <span className="wb-label">Passphrase</span>
          <input id="wb-pc-unlock" className="wb-input" type="password" autoComplete="current-password" value={pass} onChange={(e) => setPass(e.target.value)} />
        </label>
        {err && <p className="wb-error" role="alert">{err}</p>}
        <div className="wb-pc-actions">
          <Button loading={busy} onClick={() => run(() => ctl.unlock(pass))}>
            Unlock
          </Button>
          <Button variant="danger" size="sm" onClick={() => run(() => ctl.forget())}>
            Forget this key
          </Button>
        </div>
      </Card>
    )
  }

  if (!meta.registered) {
    const u = ctl.unlocked
    const fp = u ? fingerprint(u.ops.edPub, u.ops.xPub) : null
    return (
      <Card className="wb-pc-card">
        <Stepper current={approval.trim() ? 3 : 2} />
        <h2 className="wb-pc-h2">Approve this browser on your phone</h2>
        {!u ? (
          <>
            <p className="wb-hint">This browser has a viewer key but it is not unlocked (session keys are lost on reload).</p>
            <div className="wb-pc-actions">
              <Button variant="danger" size="sm" onClick={() => run(() => ctl.forget())}>
                Start over
              </Button>
            </div>
          </>
        ) : (
          <>
            <div className="wb-pc-phase">
              <h3 className="wb-pc-h3"><span className="wb-pc-num">2</span> Send the request code to your phone</h3>
              <p className="wb-hint">
                On your phone open the Private circle, <em>Approve a viewer or bridge</em>, and paste this request code.
                Compare the number below with the one the phone shows, then approve.
              </p>
              <div className="wb-pc-code">
                <code className="wb-pc-code-text">{request ?? 'Request code not shown yet'}</code>
                <div className="wb-pc-code-actions">
                  {request ? (
                    <CopyButton value={request} label="Copy request code" />
                  ) : (
                    <Button size="sm" variant="secondary" onClick={() => run(async () => setRequest(await ctl.requestCode()))}>
                      Show request code
                    </Button>
                  )}
                </div>
              </div>
              {fp && <FingerprintBox fp={fp} />}
            </div>
            <div className="wb-pc-phase">
              <h3 className="wb-pc-h3"><span className="wb-pc-num">3</span> Paste the approval from the phone</h3>
              <label className="wb-field" htmlFor="wb-pc-approval">
                <span className="wb-label">Approval code from the phone</span>
                <textarea id="wb-pc-approval" className="wb-input wb-pc-textarea" rows={3} value={approval} onChange={(e) => setApproval(e.target.value)} />
              </label>
            </div>
            {err && <p className="wb-error" role="alert">{err}</p>}
            <div className="wb-pc-actions">
              <Button loading={busy} disabled={!approval.trim()} onClick={() => run(() => ctl.register(approval))}>
                Register viewer
              </Button>
              <Button variant="ghost" size="sm" onClick={() => run(() => ctl.forget())}>
                Cancel and delete key
              </Button>
            </div>
          </>
        )}
        {!u && err && <p className="wb-error" role="alert">{err}</p>}
      </Card>
    )
  }

  const u = ctl.unlocked
  const fp = u ? fingerprint(u.ops.edPub, u.ops.xPub) : null
  return (
    <Card className="wb-pc-card">
      <Stepper current={5} />
      <div className="wb-pc-connected">
        <div>
          <h2 className="wb-pc-h2">
            This viewer <Badge tone="green" dot>Approved by your phone</Badge>
          </h2>
          <p className="wb-hint">
            {meta.name} · key kept:{' '}
            {meta.mode === 'device'
              ? 'in this browser (non-extractable)'
              : meta.mode === 'passphrase'
                ? 'passphrase protected'
                : meta.mode === 'account'
                  ? 'sealed on the server under your vault passphrase, open in this tab only'
                  : 'this visit only'}
          </p>
        </div>
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
      </div>
      {fp && <FingerprintBox fp={fp} />}
      {err && <p className="wb-error" role="alert">{err}</p>}
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
    <Card className="wb-pc-card">
      <div className="wb-pc-viewhead">
        <h2 className="wb-pc-h2">{conn.name}</h2>
        <Badge tone="green">Decrypted in your browser</Badge>
        <Badge tone={conn.phase === 'live' ? 'green' : conn.phase === 'error' || conn.phase === 'revoked' ? 'red' : 'orange'} dot>
          {phaseLabel(conn)}
        </Badge>
      </div>
      {conn.error && <p className="wb-error">{conn.error}</p>}
      {conn.phase === 'waiting-for-key' && (
        <p className="wb-pc-notice">
          Waiting for one of your phones to share this circle’s key with this viewer. Open the circle on your phone
          (Settings, Security, Encryption keys); this page keeps checking.
        </p>
      )}
      {conn.phase === 'revoked' && <p className="wb-pc-notice">This viewer is no longer approved for the circle. Revoke it and set up a new one if needed.</p>}
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
      <h3 className="wb-pc-h3">Members</h3>
      <div className="wb-table-wrap wb-pc-tablewrap"><table className="wb-table">
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
                <td><strong>{m.name}</strong></td>
                <td className="wb-muted">{p ? `${new Date(p.ts).toLocaleString()} · ${p.lat.toFixed(5)}, ${p.lon.toFixed(5)}` : 'nothing decrypted yet'}</td>
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
      </table></div>
      {who && <Trail points={conn.book.trail(who)} />}
      <DeliveryPanel circleId={conn.circleId} tick={conn.lastUpdate} />
      {conn.book.events.length > 0 && (
        <>
          <h3 className="wb-pc-h3">Recent events</h3>
          <ul className="wb-pc-events">
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
      <div className="wb-pc-actions">
        <Button size="sm" variant="secondary" onClick={() => void ctl.connect(conn.circleId, conn.name)}>
          Refresh now
        </Button>
      </div>
    </Card>
  )
}

interface DeliveryDevice {
  device_id: string
  label: string
  approved: boolean
  can_upload: boolean
  has_key_wrap: boolean
  last_item_at: string | null
}
interface DeliveryMember {
  user_id: string
  name: string
  you: boolean
  sharing_enabled: boolean
  lane: string
  app_version?: string
  app_bucket: string
  last_contact_at: string | null
  last_item_at: string | null
  reason: string
  devices: DeliveryDevice[]
}
interface DeliveryReport {
  summary: string
  epoch: number
  members: DeliveryMember[]
}

const DELIVERY_REASON: Record<string, { tone: 'green' | 'orange' | 'red'; text: (m: DeliveryMember) => string }> = {
  ok: { tone: 'green', text: () => 'Sending normally' },
  sharing_paused: { tone: 'orange', text: (m) => `Location sharing paused by ${m.name}` },
  update_needed: { tone: 'red', text: (m) => `${m.name} needs to update the app (v${m.app_version ?? '?'} is too old for private circles)` },
  no_device: { tone: 'red', text: (m) => `${m.name} has not set up encryption on a phone yet` },
  not_approved: { tone: 'red', text: (m) => `${m.name}’s phone is waiting for an admin to approve it` },
  no_key_wrap: { tone: 'red', text: (m) => `${m.name}’s phone has not received the circle key yet` },
  never_sent: { tone: 'orange', text: (m) => `${m.name} has the key but has not sent an encrypted update yet (phone off or app closed?)` },
  quiet: {
    tone: 'orange',
    text: (m) =>
      `${m.name} hasn’t sent an encrypted update since ${m.last_item_at ? new Date(m.last_item_at).toLocaleString() : 'a while'} (phone may be off or the app closed)`,
  },
}

/** Delivery: who is sending sealed updates, and why not. Metadata only, from the server; no positions. */
function DeliveryPanel({ circleId, tick }: { circleId: string; tick: unknown }) {
  const rep = useAsync(() => e2eeHttp.get<DeliveryReport>(`/circles/${circleId}/delivery`), [circleId, tick])
  return (
    <section aria-labelledby={`wb-pc-delivery-${circleId}`}>
      <h3 id={`wb-pc-delivery-${circleId}`} className="wb-pc-h3">Delivery</h3>
      <p className="wb-hint">
        Why a member might show “no location yet”. This is built from what the server already knows (key shares, when a sealed update last arrived,
        app version, sharing switch). It contains no positions.
      </p>
      {rep.loading && !rep.data ? (
        <p className="wb-hint"><Spinner /> Checking…</p>
      ) : rep.error || !rep.data ? (
        <p className="wb-hint">The server could not report delivery for this circle.</p>
      ) : (
        <>
          {rep.data.summary === 'nobody_sending' && (
            <p className="wb-pc-notice">You are in private mode and nobody has sent an update.</p>
          )}
          <div className="wb-table-wrap wb-pc-tablewrap"><table className="wb-table">
            <thead>
              <tr><th>Member</th><th>Status</th><th>Last sealed update</th><th>Phones</th><th>App</th><th>Lane</th></tr>
            </thead>
            <tbody>
              {rep.data.members.map((m) => {
                const r = DELIVERY_REASON[m.reason] ?? DELIVERY_REASON.ok!
                return (
                  <tr key={m.user_id}>
                    <td><strong>{m.name}</strong>{m.you ? ' (you)' : ''}</td>
                    <td><Badge tone={r.tone} dot>{r.text(m)}</Badge></td>
                    <td className="wb-muted">{m.last_item_at ? new Date(m.last_item_at).toLocaleString() : 'never'}</td>
                    <td className="wb-muted">
                      {m.devices.length === 0
                        ? 'none'
                        : m.devices
                            .map((d) => `${d.label || 'phone'}: ${d.has_key_wrap ? 'has key' : 'no key'}${d.approved ? '' : ', not approved'}`)
                            .join('; ')}
                    </td>
                    <td className="wb-muted">{m.app_version ? `v${m.app_version}` : 'unknown'}</td>
                    <td className="wb-muted">{m.lane === 'server' ? 'server-assisted' : 'phone only'}</td>
                  </tr>
                )
              })}
            </tbody>
          </table></div>
        </>
      )}
    </section>
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
