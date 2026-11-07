import React from 'react'
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
        The QR holds the full code as text, so you can read it with any phone camera and compare. The OpenFamily app
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

/** First-run checklist (platform admin). Hidden once finished or dismissed. */
export function ServerSetupCard() {
  const { state, setState, error } = useDeployment()
  const [email, setEmail] = React.useState('')
  const [busy, setBusy] = React.useState(false)
  if (error) return null
  if (!state) return null
  if (!showSetupCard(state)) return null
  const steps = setupSteps(state)
  const cmds = enrollCommands(email)
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  const nextIdx = steps.findIndex((s) => !s.done)

  async function dismiss() {
    setBusy(true)
    try {
      setState(await dismissServerSetup(true))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Server setup</h3>
      </div>
      <p className="wb-settings-section-help">
        Five short steps so your family can let this server see their location (for driving reports, history and the
        map). You can skip this and add the server later from the app.
      </p>
      <ol className="wb-ss-steps">
        {steps.map((s, i) => (
          <li key={s.key} className={s.done ? 'wb-ss-done' : i === nextIdx ? 'wb-ss-next' : ''}>
            <span className="wb-ss-mark" aria-hidden="true">{s.done ? '✓' : i + 1}</span>
            <div className="wb-ss-body">
              <strong>{s.title}</strong>
              <span className="wb-help">{s.detail}</span>
              {s.key === 'profile' && !s.done && <ProfileChooser state={state} onChange={setState} />}
              {s.key === 'enroll' && !s.done && (
                <div>
                  <p className="wb-help">
                    Run these on the machine that runs the server, in the folder with docker-compose.yml. The server
                    key is created in a separate container so it is never next to the database password.
                  </p>
                  <label className="wb-ss-field">
                    Your OpenFamily login email (the circle admin)
                    <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.org" />
                  </label>
                  <Cmd label="1. Switch on the server key service" text={cmds.token} />
                  <Cmd label="2. Ask for a key (it prints a request code)" text={cmds.request} />
                  <p className="wb-help">
                    3. On your phone: Settings &gt; Encryption keys &gt; Approve a viewer or bridge. Paste the request
                    code, then copy the approval code the phone shows.
                  </p>
                  <Cmd label="4. Give the approval code to the server" text={cmds.approve} />
                  <Cmd label="5. Start it" text={cmds.start} />
                  <p className="wb-help">Reload this page afterwards. Full guide: {state.docs_path}</p>
                </div>
              )}
              {s.key === 'verify' && state.server_device && (
                <div>
                  <p className="wb-help">
                    In the app, open your circle and tap &ldquo;Add server&rdquo;. It shows four groups. They must be
                    exactly these:
                  </p>
                  <ServerKeyWords device={state.server_device} />
                </div>
              )}
              {s.key === 'verify' && !state.server_device && <span className="wb-help">Waiting for step 3.</span>}
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
      <Button variant="ghost" size="sm" onClick={dismiss} loading={busy}>Hide this checklist</Button>
    </Card>
  )
}
