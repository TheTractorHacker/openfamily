import React from 'react'
import { useUnsavedChanges } from '../lib/unsaved'
import {
  ApiError,
  dismissServerSetup,
  getDeploymentProfile,
  setDeploymentProfile,
} from '../lib/api'
import {
  cloudWarnings,
  enrollCommands,
  profileSummary,
  qrText,
  serverProcessing,
  setupComplete,
  setupSteps,
  showSetupCard,
  type DeploymentState,
  type ProfileChoice,
} from '../lib/deploymentProfile'
import { qrSvg } from '../lib/qr'
import { Button, Card, CopyButton } from '../components/primitives'
import { TrustedServerDefaultCard } from './TrustedServerDefaultCard'
import './ServerSetup.css'

function useDeployment() {
  const [state, setState] = React.useState<DeploymentState | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  React.useEffect(() => {
    let live = true
    getDeploymentProfile()
      .then((r) => live && setState(r))
      .catch((e) => live && setError(e instanceof Error ? e.message : 'Could not load'))
    return () => {
      live = false
    }
  }, [])
  return { state, setState, error }
}

/** The four short groups, large, plus the QR of the full code. */
export function ServerKeyWords({ device }: { device: NonNullable<DeploymentState['server_device']> }) {
  const groups = device.short.split(' ')
  const svg = React.useMemo(() => qrSvg(qrText(device.digits)), [device.digits])
  return (
    <div className="wb-ss-key" data-testid="server-key">
      <div className="wb-ss-words" aria-label="Server key, four groups">
        {groups.map((g, i) => (
          <span key={i} className="wb-ss-word">{g}</span>
        ))}
      </div>
      <details>
        <summary>Show the full code (12 groups of digits)</summary>
        <p className="wb-ss-digits">{device.digits}</p>
      </details>
      <div className="wb-ss-qr" dangerouslySetInnerHTML={{ __html: svg }} role="img" aria-label="QR code of the full server key" />
      <p className="wb-help">
        The QR holds the full code as text, so you can read it with any phone camera and compare. The Orbitly app
        shows these same four groups when you tap &ldquo;Add server&rdquo;.
      </p>
    </div>
  )
}

function Cmd({ label, text }: { label: string; text: string }) {
  return (
    <div className="wb-ss-cmd">
      <div className="wb-ss-cmd-head">
        <span>{label}</span>
        <CopyButton value={text} label={`Copy: ${label}`} />
      </div>
      <pre>{text}</pre>
    </div>
  )
}

export function ProfileChooser({
  state,
  onChange,
}: {
  state: DeploymentState
  onChange: (s: DeploymentState) => void
}) {
  const [pick, setPick] = React.useState<ProfileChoice | ''>(state.profile)
  const [confirmHome, setConfirmHome] = React.useState(false)
  const [busy, setBusy] = React.useState(false)
  const [msg, setMsg] = React.useState<{ tone: 'ok' | 'error'; text: string } | null>(null)

  async function save() {
    if (!pick || busy) return
    setBusy(true)
    setMsg(null)
    try {
      onChange(await setDeploymentProfile(pick, confirmHome))
      setMsg({ tone: 'ok', text: 'Saved.' })
    } catch (err) {
      setMsg({ tone: 'error', text: err instanceof ApiError || err instanceof Error ? err.message : 'Could not save' })
    } finally {
      setBusy(false)
    }
  }
  const dirty = pick !== state.profile
  const canSave = !!pick && dirty && (pick !== 'home' || confirmHome)
  useUnsavedChanges(dirty, 'Where does this server run?')
  return (
    <div className="wb-ss-profile">
      <label className="wb-ss-choice">
        <input type="radio" name="profile" checked={pick === 'home'} onChange={() => setPick('home')} />
        <span>
          <strong>At home</strong> &ndash; a NAS, mini PC or Raspberry Pi that you own and that sits in your house.
        </span>
      </label>
      <label className="wb-ss-choice">
        <input type="radio" name="profile" checked={pick === 'cloud'} onChange={() => setPick('cloud')} />
        <span>
          <strong>Rented</strong> &ndash; a VPS or hosted server run by a company.
        </span>
      </label>
      {pick === 'home' && (
        <label className="wb-ss-choice wb-ss-confirm">
          <input type="checkbox" checked={confirmHome} onChange={(e) => setConfirmHome(e.target.checked)} />
          <span>I own the computer this server runs on, and nobody else can open it.</span>
        </label>
      )}
      <p className="wb-help">{profileSummary(pick === '' ? state.effective : pick, pick !== '')}</p>
      <Button size="sm" onClick={save} disabled={!canSave} loading={busy}>Save</Button>
      {msg && <p className={msg.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{msg.text}</p>}
    </div>
  )
}

/** Always-visible card in Settings: profile, at-rest honesty, and the older "trust" switch. */
export function DeploymentProfileCard() {
  const { state, setState } = useDeployment()
  if (!state) return null
  const warnings = cloudWarnings(state)
  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Where does this server run?</h3>
      </div>
      <p className="wb-settings-section-help">
        This only changes what the app suggests and how it words the warnings. Nobody is added to anything by this
        setting: every person still says yes on their own phone.
      </p>
      <ProfileChooser state={state} onChange={setState} />
      <div className="wb-settings-section">
        <h4>What is protected on the disk</h4>
        <ul className="wb-ss-list">
          <li>
            Stored secrets (
            {state.at_rest.protected_columns.map((c) => c.split('.').pop()).join(', ')}
            ): {state.at_rest.key_configured ? 'encrypted with your data key.' : 'not encrypted (no OPENFAMILY_DATA_KEY set).'}
          </li>
          <li>
            Locations, trips and history: <strong>not encrypted in the database</strong>. The server has to read them to
            draw maps, notice arrivals and build driving reports.
          </li>
          <li>Whole-disk encryption: the server cannot check this. Turn it on in the operating system or at your host.</li>
          {state.backups && (
            <li>
              Last backup: {state.backups.last_status}, {state.backups.last_encrypted ? 'encrypted' : 'NOT encrypted'}.
            </li>
          )}
        </ul>
        {warnings.map((w) => (
          <p key={w} className="wb-error-text" role="status">{w}</p>
        ))}
      </div>
      <details className="wb-ss-adv">
        <summary>Advanced: older &ldquo;trust this server&rdquo; switch</summary>
        <TrustedServerDefaultCard />
      </details>
    </Card>
  )
}

/** Details: the older manual route (separate sidecar container) for advanced and cloud operators. */
function ManualRoute({ state }: { state: DeploymentState }) {
  const [email, setEmail] = React.useState('')
  const cmds = enrollCommands(email)
  return (
    <details className="wb-ss-adv">
      <summary>Details: run the server key in a separate container (advanced)</summary>
      <p className="wb-help">
        Not needed for a normal install: the server creates its own key. Use this only if you want the key in a
        separate container, away from the database (see {state.docs_path}). Run these on the machine that runs the
        server.
      </p>
      <label className="wb-ss-field">
        Your Orbitly login email (the server admin)
        <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.org" />
      </label>
      <Cmd label="1. Switch on the key container" text={cmds.token} />
      <Cmd label="2. Ask for a key (it prints a request code)" text={cmds.request} />
      <p className="wb-help">
        3. On your phone: Settings &gt; Encryption keys &gt; Approve a viewer or bridge. Paste the request code, then
        copy the approval code the phone shows.
      </p>
      <Cmd label="4. Give the approval code to the server" text={cmds.approve} />
      <Cmd label="5. Start it" text={cmds.start} />
    </details>
  )
}

/** First-run setup (platform admin): three steps, then a green "Server is processing" line. */
export function ServerSetupCard() {
  const { state, setState, error } = useDeployment()
  const [busy, setBusy] = React.useState(false)
  // While the server waits for approval, look again every few seconds so the card completes by itself.
  React.useEffect(() => {
    if (!state || setupComplete(state)) return
    const t = setInterval(() => getDeploymentProfile().then(setState).catch(() => {}), 5000)
    return () => clearInterval(t)
  }, [state, setState])
  if (error || !state) return null
  const origin = typeof window !== 'undefined' ? window.location.origin : ''

  if (serverProcessing(state)) {
    return (
      <Card>
        <p className="wb-ss-ok" role="status" data-testid="server-processing">
          <span aria-hidden="true">✓ </span>
          <strong>Server is processing</strong> &ndash; maps, history and driving reports work for everyone who chose
          the server.
        </p>
        {(state.private_circles_without_server ?? 0) > 0 && (
          <p className="wb-help" data-testid="private-circles-hint">
            {state.private_circles_without_server} private circle(s) are not using the server yet. A circle admin opens
            the app and taps &ldquo;Let the server do the processing (recommended)&rdquo;; then each member taps
            &ldquo;Use the server&rdquo;. The admin web cannot do this for them: it needs their phone&rsquo;s keys.
          </p>
        )}
        <details className="wb-ss-adv">
          <summary>Details</summary>
          {state.builtin && (
            <p className="wb-help">
              The server uses its own built-in key (state: {state.builtin.state}
              {state.builtin.sealed ? ', sealed with your data key' : ''}). Its private key lives on this
              machine&rsquo;s data volume.
            </p>
          )}
          {state.server_device && <ServerKeyWords device={state.server_device} />}
          <ManualRoute state={state} />
        </details>
      </Card>
    )
  }
  if (!showSetupCard(state)) return null
  const steps = setupSteps(state)
  const nextIdx = steps.findIndex((s) => !s.done)

  async function dismiss() {
    setBusy(true)
    try {
      setState(await dismissServerSetup(true))
    } finally {
      setBusy(false)
    }
  }

  const waiting = state.builtin && !state.builtin.registered

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Server setup</h3>
      </div>
      <p className="wb-settings-section-help">
        Three short steps so this server can keep maps, history and driving reports for your people. Everyone still
        chooses for themselves in the app whether the server may use their location.
      </p>
      <ol className="wb-ss-steps">
        {steps.map((s, i) => (
          <li key={s.key} className={s.done ? 'wb-ss-done' : i === nextIdx ? 'wb-ss-next' : ''}>
            <span className="wb-ss-mark" aria-hidden="true">{s.done ? '✓' : i + 1}</span>
            <div className="wb-ss-body">
              <strong>{s.title}</strong>
              <span className="wb-help">{s.detail}</span>
              {s.key === 'profile' && !s.done && <ProfileChooser state={state} onChange={setState} />}
              {s.key === 'approve' && !s.done && waiting && state.builtin && (
                <div data-testid="server-join-code">
                  <p className="wb-help">
                    Open Orbitly on your phone (you get a message &ldquo;Your server wants to join&rdquo;; if not,
                    the same prompt shows at the top of the app). It must show this code:
                  </p>
                  <ServerKeyWords
                    device={{ device_id: '', label: 'Orbitly server', fingerprint: state.builtin.fingerprint, short: state.builtin.short, digits: state.builtin.digits }}
                  />
                </div>
              )}
              {s.key === 'approve' && !s.done && !waiting && (
                <span className="wb-help">
                  This server uses a separate key container. Open &ldquo;Details&rdquo; below to finish it.
                </span>
              )}
              {s.key === 'apps' && (
                <ul className="wb-ss-list">
                  <li>
                    Android: open <a href={`${origin}/app.apk`}>{origin}/app.apk</a> on the phone (or install from your
                    app store when available).
                  </li>
                  <li>iPhone: see the install guide for the current route.</li>
                  <li>In the app, create a circle, then Invite: share the code. Everyone enters it when they join.</li>
                </ul>
              )}
            </div>
          </li>
        ))}
      </ol>
      <ManualRoute state={state} />
      <Button variant="ghost" size="sm" onClick={dismiss} loading={busy}>Hide this checklist</Button>
    </Card>
  )
}
