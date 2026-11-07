// Backup settings form (System page > Backups). Edits the S3 destination,
// encryption key, schedule and retention. The S3 credentials are WRITE-ONLY:
// the server never returns them; this form only shows that they are set and
// lets the admin replace or clear them. A value set by the server environment
// is shown read-only ("Set by environment").

import React from 'react'
import { ApiError, getBackupSettings, putBackupSettings, testBackupS3 } from '../lib/api'
import { generateAgeKeyPair, type AgeKeyPair } from '../lib/age'
import { cronToDaily, dailyToCron, parseRecipients, validateForm } from '../lib/backups'
import type { BackupSettingsResponse, BackupSettingsSubmit, BackupSettingsValues } from '../lib/types'
import { Badge, Button, Card, Spinner } from '../components/primitives'
import { Alert } from '../components/patterns'
import './BackupSettings.css'

type CredMode = 'keep' | 'replace' | 'clear'

const errText = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : 'Request failed')

function timeZones(): string[] {
  try {
    const f = (Intl as unknown as { supportedValuesOf?: (k: string) => string[] }).supportedValuesOf
    if (f) return f('timeZone')
  } catch {
    // fall through
  }
  return ['UTC']
}

function download(name: string, text: string) {
  const url = URL.createObjectURL(new Blob([text + '\n'], { type: 'text/plain' }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.click()
  URL.revokeObjectURL(url)
}

interface FieldProps {
  id: string
  label: string
  field?: string
  hint?: React.ReactNode
  error?: string
  src?: string
  pinned?: boolean
  children: React.ReactNode
  wide?: boolean
}

function Field({ id, label, field, hint, error, src, pinned, children, wide }: FieldProps) {
  return (
    <div className={`wb-bkf-field${wide ? ' wb-bkf-wide' : ''}`} data-field={field}>
      <label className="wb-label" htmlFor={id}>
        {label}
        {pinned ? (
          <Badge tone="purple" title="Set in the server's .env; change it there">Set by environment</Badge>
        ) : src === 'ui' ? (
          <span className="wb-bkf-src">saved</span>
        ) : src === 'default' ? (
          <span className="wb-bkf-src">default</span>
        ) : null}
      </label>
      {children}
      {error ? (
        <p className="wb-bkf-err" id={`${id}-err`} role="alert">
          {error}
        </p>
      ) : hint ? (
        <p className="wb-bkf-hint">{hint}</p>
      ) : null}
    </div>
  )
}

function Toggle({ id, checked, onChange, disabled, label, hint }: { id: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; label: string; hint?: string }) {
  return (
    <label className={`wb-bkf-toggle${disabled ? ' is-disabled' : ''}`} htmlFor={id}>
      <input id={id} type="checkbox" role="switch" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span className="wb-bkf-toggle-track" aria-hidden="true" />
      <span className="wb-bkf-toggle-text">
        <span className="wb-bkf-toggle-label">{label}</span>
        {hint && <span className="wb-bkf-hint">{hint}</span>}
      </span>
    </label>
  )
}

export function BackupSettings({ onChanged }: { onChanged?: () => void }) {
  const [resp, setResp] = React.useState<BackupSettingsResponse | null>(null)
  const [loadError, setLoadError] = React.useState<string | null>(null)
  const [form, setForm] = React.useState<BackupSettingsValues | null>(null)
  const [initial, setInitial] = React.useState('')
  const [recText, setRecText] = React.useState('')
  const [dailyMode, setDailyMode] = React.useState(true)
  const [keyId, setKeyId] = React.useState('')
  const [secret, setSecret] = React.useState('')
  const [credMode, setCredMode] = React.useState<CredMode>('keep')
  const [errors, setErrors] = React.useState<Record<string, string>>({})
  const [busy, setBusy] = React.useState<'save' | 'test' | null>(null)
  const [msg, setMsg] = React.useState<{ tone: 'success' | 'danger' | 'info'; text: string } | null>(null)
  const [pair, setPair] = React.useState<AgeKeyPair | null>(null)
  const [pairSaved, setPairSaved] = React.useState(false)
  const [copied, setCopied] = React.useState(false)
  const zones = React.useMemo(timeZones, [])

  const apply = React.useCallback((r: BackupSettingsResponse) => {
    setResp(r)
    setForm(r.values)
    setRecText(r.values.age_recipients.join('\n'))
    setDailyMode(cronToDaily(r.values.schedule) !== null)
    setKeyId('')
    setSecret('')
    setCredMode('keep')
    setErrors({})
    setInitial(JSON.stringify([r.values, '', '', 'keep']))
  }, [])

  React.useEffect(() => {
    let live = true
    getBackupSettings()
      .then((r) => live && apply(r))
      .catch((e) => live && setLoadError(errText(e)))
    return () => {
      live = false
    }
  }, [apply])

  const pinned = React.useMemo(() => new Set(resp?.pinned ?? []), [resp])
  const credPinned = resp?.credentials.pinned ?? false

  if (loadError) return <Alert tone="danger" title="Couldn’t load backup settings">{loadError}</Alert>
  if (!resp || !form) {
    return (
      <div className="wb-page-loading">
        <Spinner /> Loading…
      </div>
    )
  }

  const set = <K extends keyof BackupSettingsValues>(k: K, v: BackupSettingsValues[K]) => {
    setForm({ ...form, [k]: v })
    setMsg(null)
  }
  const dirty = JSON.stringify([form, keyId, secret, credMode]) !== initial
  const src = (f: string) => resp.sources[f]
  const pin = (f: string) => pinned.has(f)
  const daily = cronToDaily(form.schedule)

  const submit = (): BackupSettingsSubmit => {
    const body: BackupSettingsSubmit = { settings: { ...form, age_recipients: parseRecipients(recText) } }
    if (credMode === 'replace') {
      body.access_key_id = keyId.trim()
      body.secret_access_key = secret
    } else if (credMode === 'clear') {
      body.clear_credentials = true
    }
    return body
  }

  const check = (): boolean => {
    const v = { ...form, age_recipients: parseRecipients(recText) }
    const e = validateForm(v, pinned)
    if (form.s3_enabled && !credPinned && credMode === 'replace' && (!keyId.trim() || !secret)) e.access_key_id = 'Enter both the access key id and the secret'
    if (form.s3_enabled && !credPinned && credMode !== 'replace' && !resp.credentials.access_key_set) e.access_key_id = 'S3 needs an access key'
    if (form.s3_enabled && !credPinned && credMode === 'clear') e.access_key_id = 'S3 needs an access key; disable S3 to clear it'
    if (form.s3_enabled && v.age_recipients.length === 0 && !pin('age_recipients') && !e.age_recipients) e.age_recipients = 'S3 backups must be encrypted: add your age public key (Generate key pair does it for you)'
    setErrors(e)
    return Object.keys(e).length === 0
  }

  const serverErrors = (e: unknown) => {
    if (e instanceof ApiError && e.fields) {
      const f = { ...e.fields }
      setErrors(f)
      setMsg({ tone: 'danger', text: 'Fix the highlighted fields.' })
    } else {
      setMsg({ tone: 'danger', text: errText(e) })
    }
  }

  const save = async () => {
    if (!check()) {
      setMsg({ tone: 'danger', text: 'Fix the highlighted fields.' })
      return
    }
    setBusy('save')
    setMsg(null)
    try {
      const r = await putBackupSettings(submit())
      apply(r)
      setMsg({ tone: 'success', text: 'Saved. The backup service applies it within a few seconds; no restart needed.' })
      onChanged?.()
    } catch (e) {
      serverErrors(e)
    } finally {
      setBusy(null)
    }
  }

  const test = async () => {
    if (!check()) {
      setMsg({ tone: 'danger', text: 'Fix the highlighted fields first.' })
      return
    }
    setBusy('test')
    setMsg(null)
    try {
      await testBackupS3(submit())
      setMsg({ tone: 'info', text: 'Connection test queued with the values above (saved or not). The result appears at the top of this card.' })
      onChanged?.()
    } catch (e) {
      serverErrors(e)
    } finally {
      setBusy(null)
    }
  }

  const useKey = () => {
    if (!pair) return
    const keys = parseRecipients(recText)
    if (!keys.includes(pair.publicKey)) keys.push(pair.publicKey)
    setRecText(keys.join('\n'))
    setPair(null)
    setPairSaved(false)
    setErrors({ ...errors, age_recipients: '' })
    setMsg({ tone: 'info', text: 'The public key was added. Save to use it. The private key is gone from this page.' })
  }

  const copy = async () => {
    if (pair && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(pair.privateKey).catch(() => undefined)
      setCopied(true)
    }
  }

  const inp = (id: string, f: string, extra: React.InputHTMLAttributes<HTMLInputElement> = {}) => ({
    id,
    className: `wb-input${errors[f] ? ' is-invalid' : ''}`,
    disabled: pin(f) || busy !== null,
    'aria-invalid': errors[f] ? true : undefined,
    'aria-describedby': errors[f] ? `${id}-err` : undefined,
    ...extra,
  })

  return (
    <div className="wb-bkf">
      {resp.settings_error && (
        <Alert tone="danger" title="The saved settings could not be applied">
          {resp.settings_error} The backup service keeps running with its previous configuration.
        </Alert>
      )}
      {!resp.agent_reporting && (
        <Alert tone="info" title="The backup service is not reporting">
          You can save settings now; they apply when the service starts. Settings pinned by <code>.env</code> are only
          shown as read-only once the service has reported.
        </Alert>
      )}

      <Card>
        <fieldset className="wb-bkf-group" disabled={busy !== null}>
          <legend className="wb-bkf-legend">Destinations</legend>
          <Toggle id="bk-local" checked={form.local_enabled} disabled={pin('local_enabled')} onChange={(v) => set('local_enabled', v)}
            label="Local disk" hint="Keep encrypted copies in the ./backups folder next to docker-compose.yml." />
          <Toggle id="bk-s3" checked={form.s3_enabled} disabled={pin('s3_enabled')} onChange={(v) => set('s3_enabled', v)}
            label="S3-compatible storage" hint="AWS S3, Backblaze B2, Wasabi, Cloudflare R2, MinIO or any S3 API." />
          {pin('s3_enabled') && <Badge tone="purple">S3 is configured in .env</Badge>}

          {form.s3_enabled && (
            <div className="wb-bkf-grid">
              <Field id="bk-endpoint" label="Endpoint" field="endpoint" src={src('endpoint')} pinned={pin('endpoint')} error={errors.endpoint}
                hint="Leave empty for AWS S3. Otherwise https://host[:port], e.g. s3.us-west-004.backblazeb2.com.">
                <input {...inp('bk-endpoint', 'endpoint', { type: 'text', inputMode: 'url', autoComplete: 'off', placeholder: 'https://s3.example.com' })}
                  value={form.endpoint} onChange={(e) => set('endpoint', e.target.value)} />
              </Field>
              <Field id="bk-region" label="Region" field="region" src={src('region')} pinned={pin('region')} error={errors.region} hint="e.g. eu-central-1, or auto for Cloudflare R2.">
                <input {...inp('bk-region', 'region', { type: 'text', autoComplete: 'off' })} value={form.region} onChange={(e) => set('region', e.target.value)} />
              </Field>
              <Field id="bk-bucket" label="Bucket" field="bucket" src={src('bucket')} pinned={pin('bucket')} error={errors.bucket}>
                <input {...inp('bk-bucket', 'bucket', { type: 'text', autoComplete: 'off', placeholder: 'my-family-backups' })} value={form.bucket} onChange={(e) => set('bucket', e.target.value)} />
              </Field>
              <Field id="bk-prefix" label="Folder (prefix)" field="prefix" src={src('prefix')} pinned={pin('prefix')} error={errors.prefix} hint="Backups are stored under this folder.">
                <input {...inp('bk-prefix', 'prefix', { type: 'text', autoComplete: 'off' })} value={form.prefix} onChange={(e) => set('prefix', e.target.value)} />
              </Field>
              <Field id="bk-class" label="Storage class" field="storage_class" src={src('storage_class')} pinned={pin('storage_class')} error={errors.storage_class} hint="Optional, AWS only (e.g. STANDARD_IA).">
                <input {...inp('bk-class', 'storage_class', { type: 'text', autoComplete: 'off' })} value={form.storage_class} onChange={(e) => set('storage_class', e.target.value)} />
              </Field>
              <div className="wb-bkf-field wb-bkf-toggles">
                <Toggle id="bk-path" checked={form.path_style} disabled={pin('path_style') || busy !== null} onChange={(v) => set('path_style', v)} label="Path-style addressing" hint="Needed by MinIO and some self-hosted stores." />
                <Toggle id="bk-insecure" checked={form.insecure} disabled={pin('insecure') || busy !== null} onChange={(v) => set('insecure', v)} label="Allow plain HTTP" hint="Only for a MinIO on your own network." />
                <Toggle id="bk-private" checked={form.allow_private} disabled={pin('allow_private') || busy !== null} onChange={(v) => set('allow_private', v)} label="Allow private network address" hint="Needed when the server is on your LAN or this machine. Cloud metadata addresses stay blocked." />
              </div>

              <div className="wb-bkf-field wb-bkf-wide wb-bkf-creds" data-field="credentials">
                <span className="wb-label">
                  Access key
                  {credPinned && <Badge tone="purple" title="Set in the server's .env; change it there">Set by environment</Badge>}
                </span>
                {credPinned ? (
                  <p className="wb-bkf-hint">The access key and secret are provided by the server environment.</p>
                ) : credMode === 'replace' || !resp.credentials.access_key_set ? (
                  <div className="wb-bkf-credrow">
                    <input id="bk-keyid" className={`wb-input${errors.access_key_id ? ' is-invalid' : ''}`} type="text" autoComplete="off" spellCheck={false}
                      placeholder="Access key id" aria-label="Access key id" value={keyId}
                      onChange={(e) => { setKeyId(e.target.value); setCredMode('replace') }} />
                    <input id="bk-secret" className={`wb-input${errors.secret_access_key ? ' is-invalid' : ''}`} type="password" autoComplete="new-password" spellCheck={false}
                      placeholder="Secret access key" aria-label="Secret access key" value={secret}
                      onChange={(e) => { setSecret(e.target.value); setCredMode('replace') }} />
                    {resp.credentials.access_key_set && (
                      <Button variant="ghost" size="sm" type="button" onClick={() => { setCredMode('keep'); setKeyId(''); setSecret('') }}>Keep current</Button>
                    )}
                  </div>
                ) : (
                  <div className="wb-bkf-credrow">
                    <Badge tone="green" dot>Set {resp.credentials.access_key_hint}</Badge>
                    <span className="wb-bkf-hint">The secret is stored encrypted and is never shown again.</span>
                    <Button variant="secondary" size="sm" type="button" onClick={() => setCredMode('replace')}>Replace</Button>
                    <Button variant="ghost" size="sm" type="button" onClick={() => setCredMode('clear')}>Clear</Button>
                  </div>
                )}
                {credMode === 'clear' && !credPinned && <p className="wb-bkf-hint">The stored key will be removed when you save.</p>}
                {resp.credentials.unreadable && <p className="wb-bkf-err">The stored key can no longer be decrypted (the server key changed). Replace it.</p>}
                {(errors.access_key_id || errors.secret_access_key) && <p className="wb-bkf-err" role="alert">{errors.access_key_id ?? errors.secret_access_key}</p>}
                <p className="wb-bkf-hint">Use a key limited to this bucket and folder (list, put, get, delete). Stored encrypted with a key derived from the server's secrets.</p>
              </div>
            </div>
          )}
        </fieldset>
      </Card>

      <Card>
        <fieldset className="wb-bkf-group" disabled={busy !== null}>
          <legend className="wb-bkf-legend">Encryption</legend>
          <Field id="bk-recipients" label="Public key(s)" field="age_recipients" src={src('age_recipients')} pinned={pin('age_recipients')} error={errors.age_recipients} wide
            hint="Backups are encrypted on the server before upload with these age public keys (age1...). Only the matching private key can decrypt them.">
            <textarea id="bk-recipients" className={`wb-input wb-bkf-area${errors.age_recipients ? ' is-invalid' : ''}`} rows={2} spellCheck={false} placeholder="age1..."
              disabled={pin('age_recipients') || busy !== null} value={recText} onChange={(e) => { setRecText(e.target.value); setMsg(null) }} />
          </Field>
          {!pin('age_recipients') && !pair && (
            <div>
              <Button variant="secondary" size="sm" type="button" onClick={() => { setPair(generateAgeKeyPair()); setPairSaved(false); setCopied(false) }}>
                Generate key pair
              </Button>
              <span className="wb-bkf-hint wb-bkf-inline"> Creates the pair in your browser. The server never sees the private key.</span>
            </div>
          )}
          {pair && (
            <div className="wb-bkf-keybox" role="group" aria-label="New private key">
              <Alert tone="danger" title="Save the private key now. It is shown only once.">
                <strong>The server never stores it, and without it your backups can NOT be restored.</strong> Put it in a password manager and on a
                second offline copy. If you lose it, every encrypted backup is permanently unreadable.
              </Alert>
              <code className="wb-bkf-secret" data-testid="private-key">{pair.privateKey}</code>
              <div className="wb-bkf-keyactions">
                <Button variant="secondary" size="sm" type="button" onClick={() => void copy()}>{copied ? 'Copied' : 'Copy private key'}</Button>
                <Button variant="secondary" size="sm" type="button" onClick={() => download('openfamily-backup.key', pair.privateKey)}>Download file</Button>
              </div>
              <label className="wb-bkf-check">
                <input type="checkbox" checked={pairSaved} onChange={(e) => setPairSaved(e.target.checked)} />
                <span>I saved the private key somewhere safe</span>
              </label>
              <div className="wb-bkf-keyactions">
                <Button size="sm" type="button" disabled={!pairSaved} onClick={useKey}>Use the public key</Button>
                <Button variant="ghost" size="sm" type="button" onClick={() => setPair(null)}>Discard</Button>
              </div>
              <p className="wb-bkf-hint">Public key: <code>{pair.publicKey}</code></p>
            </div>
          )}
        </fieldset>
      </Card>

      <Card>
        <fieldset className="wb-bkf-group" disabled={busy !== null}>
          <legend className="wb-bkf-legend">Schedule</legend>
          <div className="wb-bkf-grid">
            {dailyMode ? (
              <Field id="bk-time" label="Daily at" field="schedule" src={src('schedule')} pinned={pin('schedule')} error={errors.schedule}>
                <input {...inp('bk-time', 'schedule', { type: 'time' })} value={daily ?? '03:15'}
                  onChange={(e) => { const c = dailyToCron(e.target.value); if (c) set('schedule', c) }} />
              </Field>
            ) : (
              <Field id="bk-cron" label="Cron schedule" field="schedule" src={src('schedule')} pinned={pin('schedule')} error={errors.schedule} hint="minute hour day-of-month month day-of-week, e.g. 15 3 * * *">
                <input {...inp('bk-cron', 'schedule', { type: 'text', autoComplete: 'off', spellCheck: false })} value={form.schedule} onChange={(e) => set('schedule', e.target.value)} />
              </Field>
            )}
            <Field id="bk-tz" label="Time zone" field="timezone" src={src('timezone')} pinned={pin('timezone')} error={errors.timezone}>
              <input {...inp('bk-tz', 'timezone', { type: 'text', list: 'bk-tz-list', autoComplete: 'off' })} value={form.timezone} onChange={(e) => set('timezone', e.target.value)} />
              <datalist id="bk-tz-list">{zones.map((z) => <option key={z} value={z} />)}</datalist>
            </Field>
          </div>
          {!pin('schedule') && (
            <button type="button" className="wb-bkf-link" onClick={() => { if (dailyMode) setDailyMode(false); else if (daily !== null) setDailyMode(true) }}>
              {dailyMode ? 'Use a cron expression' : daily !== null ? 'Use a daily time' : 'Custom schedules need a cron expression'}
            </button>
          )}
        </fieldset>
      </Card>

      <Card>
        <fieldset className="wb-bkf-group" disabled={busy !== null}>
          <legend className="wb-bkf-legend">Retention and alerts</legend>
          <p className="wb-bkf-hint">Keeps the newest backup of each day, week and month; deletes older ones. The newest backup is never deleted. 0 turns a tier off; all three at 0 keeps everything.</p>
          <div className="wb-bkf-grid wb-bkf-grid-4">
            {([['keep_daily', 'Daily', 'bk-kd'], ['keep_weekly', 'Weekly', 'bk-kw'], ['keep_monthly', 'Monthly', 'bk-km']] as const).map(([f, label, id]) => (
              <Field key={f} id={id} label={label} field={f} src={src(f)} pinned={pin(f)} error={errors[f]}>
                <input {...inp(id, f, { type: 'number', min: 0, max: 3650 })} value={form[f]} onChange={(e) => set(f, Number(e.target.value))} />
              </Field>
            ))}
            <Field id="bk-stale" label="Warn after (hours)" field="stale_hours" src={src('stale_hours')} pinned={pin('stale_hours')} error={errors.stale_hours}>
              <input {...inp('bk-stale', 'stale_hours', { type: 'number', min: 1, max: 8760 })} value={form.stale_hours} onChange={(e) => set('stale_hours', Number(e.target.value))} />
            </Field>
          </div>
        </fieldset>
      </Card>

      {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
      <div className="wb-bkf-actions">
        <span className={`wb-bkf-state${dirty ? ' is-dirty' : ''}`} role="status">{dirty ? 'Unsaved changes' : 'All changes saved'}</span>
        <Button variant="ghost" type="button" disabled={!dirty || busy !== null} onClick={() => { apply(resp); setMsg(null) }}>Discard</Button>
        {form.s3_enabled && (
          <Button variant="secondary" type="button" loading={busy === 'test'} disabled={busy !== null} onClick={() => void test()}>
            Test connection
          </Button>
        )}
        <Button type="button" loading={busy === 'save'} disabled={!dirty || busy !== null} onClick={() => void save()}>
          Save settings
        </Button>
      </div>
    </div>
  )
}
