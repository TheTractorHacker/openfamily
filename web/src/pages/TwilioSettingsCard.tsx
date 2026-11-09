import React from 'react'
import { useUnsavedChanges } from '../lib/unsaved'
import { ApiError, clearSmsSettings, getSmsSettings, updateSmsSettings } from '../lib/api'
import type { SmsSettings } from '../lib/types'
import { Badge, Button, Card } from '../components/primitives'

type FormMessage = { tone: 'success' | 'error'; text: string } | null

interface FieldErrors {
  account_sid?: string
  auth_token?: string
  from?: string
  public_base_url?: string
}

function messageFromError(error: unknown, fallback: string): string {
  if (error instanceof ApiError) return error.message || fallback
  if (error instanceof Error) return error.message || fallback
  return fallback
}

function applySettings(settings: SmsSettings) {
  return {
    accountSid: settings.account_sid,
    from: settings.from,
    publicBaseUrl: settings.public_base_url,
  }
}

function clientFieldErrors(input: {
  accountSid: string
  authToken: string
  from: string
  publicBaseUrl: string
  tokenAlreadySet: boolean
}): FieldErrors {
  const errors: FieldErrors = {}
  if (!input.accountSid.trim()) errors.account_sid = 'Enter your Twilio Account SID.'
  if (!input.from.trim()) errors.from = 'Enter the Twilio number SMS should come from.'
  if (!input.authToken.trim() && !input.tokenAlreadySet) {
    errors.auth_token = 'Enter the Twilio Auth Token.'
  }
  const base = input.publicBaseUrl.trim()
  if (base && !/^https:\/\/[^/\s]+/i.test(base)) {
    errors.public_base_url = 'Use an https address, for example https://orbitly.example.com.'
  }
  return errors
}

function firstErrorKey(errors: FieldErrors): keyof FieldErrors | null {
  if (errors.account_sid) return 'account_sid'
  if (errors.auth_token) return 'auth_token'
  if (errors.from) return 'from'
  if (errors.public_base_url) return 'public_base_url'
  return null
}

export function TwilioSettingsCard() {
  const accountSidRef = React.useRef<HTMLInputElement>(null)
  const authTokenRef = React.useRef<HTMLInputElement>(null)
  const fromRef = React.useRef<HTMLInputElement>(null)
  const publicBaseUrlRef = React.useRef<HTMLInputElement>(null)

  const [settings, setSettings] = React.useState<SmsSettings | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [loadError, setLoadError] = React.useState<string | null>(null)
  const [accountSid, setAccountSid] = React.useState('')
  const [authToken, setAuthToken] = React.useState('')
  const [from, setFrom] = React.useState('')
  const [publicBaseUrl, setPublicBaseUrl] = React.useState('')
  const [saving, setSaving] = React.useState(false)
  const [clearing, setClearing] = React.useState(false)
  const [fieldErrors, setFieldErrors] = React.useState<FieldErrors>({})
  const [message, setMessage] = React.useState<FormMessage>(null)

  const hydrate = React.useCallback((next: SmsSettings) => {
    setSettings(next)
    const draft = applySettings(next)
    setAccountSid(draft.accountSid)
    setFrom(draft.from)
    setPublicBaseUrl(draft.publicBaseUrl)
    setAuthToken('')
    setFieldErrors({})
  }, [])

  const refresh = React.useCallback(async () => {
    setLoading(true)
    setLoadError(null)
    try {
      hydrate(await getSmsSettings())
    } catch (error) {
      setLoadError(messageFromError(error, 'Could not load Twilio settings.'))
    } finally {
      setLoading(false)
    }
  }, [hydrate])

  React.useEffect(() => {
    void refresh()
  }, [refresh])

  const dirty = React.useMemo(() => {
    if (!settings) return Boolean(accountSid || authToken || from || publicBaseUrl)
    const initial = applySettings(settings)
    return (
      accountSid !== initial.accountSid ||
      from !== initial.from ||
      publicBaseUrl !== initial.publicBaseUrl ||
      authToken !== ''
    )
  }, [accountSid, authToken, from, publicBaseUrl, settings])

  useUnsavedChanges(dirty, 'Text messages (SMS)')

  const focusField = (key: keyof FieldErrors) => {
    const refs = {
      account_sid: accountSidRef,
      auth_token: authTokenRef,
      from: fromRef,
      public_base_url: publicBaseUrlRef,
    }
    refs[key].current?.focus()
  }

  const save = async (event: React.FormEvent) => {
    event.preventDefault()
    if (saving || clearing) return

    const errors = clientFieldErrors({
      accountSid,
      authToken,
      from,
      publicBaseUrl,
      tokenAlreadySet: Boolean(settings?.auth_token_set),
    })
    setFieldErrors(errors)
    const first = firstErrorKey(errors)
    if (first) {
      setMessage(null)
      focusField(first)
      return
    }

    setMessage(null)
    setSaving(true)
    try {
      const updated = await updateSmsSettings({
        account_sid: accountSid.trim(),
        auth_token: authToken.trim(),
        from: from.trim(),
        public_base_url: publicBaseUrl.trim(),
      })
      hydrate(updated)
      setMessage({
        tone: 'success',
        text: updated.configured
          ? 'SMS is on. Emergency contacts will appear in the app.'
          : 'Settings saved.',
      })
    } catch (error) {
      setMessage({ tone: 'error', text: messageFromError(error, 'Could not save Twilio settings.') })
    } finally {
      setSaving(false)
    }
  }

  const clearSaved = async () => {
    if (saving || clearing || settings?.source !== 'settings') return
    setMessage(null)
    setClearing(true)
    try {
      const updated = await clearSmsSettings()
      hydrate(updated)
      setMessage({
        tone: 'success',
        text: updated.configured
          ? 'Cleared saved settings. Environment values are in use.'
          : 'SMS is off. Emergency contacts are hidden in the app.',
      })
    } catch (error) {
      setMessage({ tone: 'error', text: messageFromError(error, 'Could not clear Twilio settings.') })
    } finally {
      setClearing(false)
    }
  }

  const configured = Boolean(settings?.configured)

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Twilio SMS</h3>
        <Badge tone={configured ? 'green' : 'grey'} dot>
          {loading && !settings ? 'Checking…' : configured ? 'SMS on' : 'SMS off'}
        </Badge>
      </div>
      <p className="wb-settings-section-help">
        Text SOS alerts to people who are not in your circles and do not have the app.
      </p>

      {loadError && (
        <div className="wb-profile-load-error" role="alert">
          <span>{loadError}</span>
          <Button type="button" variant="secondary" size="sm" onClick={() => void refresh()}>
            Try again
          </Button>
        </div>
      )}

      <form className="wb-settings-section wb-settings-section-flush" onSubmit={(event) => void save(event)}>
        <label className="wb-field" htmlFor="wb-twilio-sid">
          <span className="wb-label">Account SID</span>
          <input
            ref={accountSidRef}
            id="wb-twilio-sid"
            className={`wb-input${fieldErrors.account_sid ? ' wb-error-input' : ''}`}
            value={accountSid}
            onChange={(event) => setAccountSid(event.target.value)}
            placeholder="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            autoComplete="off"
            spellCheck={false}
            disabled={saving || clearing}
            aria-invalid={Boolean(fieldErrors.account_sid)}
            aria-describedby={fieldErrors.account_sid ? 'wb-twilio-sid-error' : undefined}
          />
          {fieldErrors.account_sid && (
            <span id="wb-twilio-sid-error" className="wb-error-text" role="alert">
              {fieldErrors.account_sid}
            </span>
          )}
        </label>

        <label className="wb-field" htmlFor="wb-twilio-token">
          <span className="wb-label">Auth token</span>
          <input
            ref={authTokenRef}
            id="wb-twilio-token"
            className={`wb-input${fieldErrors.auth_token ? ' wb-error-input' : ''}`}
            type="password"
            value={authToken}
            onChange={(event) => setAuthToken(event.target.value)}
            placeholder={settings?.auth_token_set ? 'Leave blank to keep the current token' : 'Twilio auth token'}
            autoComplete="off"
            spellCheck={false}
            disabled={saving || clearing}
            aria-invalid={Boolean(fieldErrors.auth_token)}
            aria-describedby={fieldErrors.auth_token ? 'wb-twilio-token-error' : undefined}
          />
          {fieldErrors.auth_token && (
            <span id="wb-twilio-token-error" className="wb-error-text" role="alert">
              {fieldErrors.auth_token}
            </span>
          )}
        </label>

        <label className="wb-field" htmlFor="wb-twilio-from">
          <span className="wb-label">From number</span>
          <input
            ref={fromRef}
            id="wb-twilio-from"
            className={`wb-input${fieldErrors.from ? ' wb-error-input' : ''}`}
            type="tel"
            inputMode="tel"
            value={from}
            onChange={(event) => setFrom(event.target.value)}
            placeholder="+15551234567"
            autoComplete="off"
            disabled={saving || clearing}
            aria-invalid={Boolean(fieldErrors.from)}
            aria-describedby={fieldErrors.from ? 'wb-twilio-from-error' : undefined}
          />
          {fieldErrors.from && (
            <span id="wb-twilio-from-error" className="wb-error-text" role="alert">
              {fieldErrors.from}
            </span>
          )}
        </label>

        <label className="wb-field" htmlFor="wb-twilio-base-url">
          <span className="wb-label">Public server address</span>
          <input
            ref={publicBaseUrlRef}
            id="wb-twilio-base-url"
            className={`wb-input${fieldErrors.public_base_url ? ' wb-error-input' : ''}`}
            type="url"
            inputMode="url"
            value={publicBaseUrl}
            onChange={(event) => setPublicBaseUrl(event.target.value)}
            placeholder="https://orbitly.example.com"
            autoComplete="off"
            spellCheck={false}
            disabled={saving || clearing}
            aria-invalid={Boolean(fieldErrors.public_base_url)}
            aria-describedby={
              fieldErrors.public_base_url ? 'wb-twilio-base-url-error' : 'wb-twilio-base-url-help'
            }
          />
          <span id="wb-twilio-base-url-help" className="wb-help">
            Used for SOS links. Leave empty to send coordinates instead.
          </span>
          {fieldErrors.public_base_url && (
            <span id="wb-twilio-base-url-error" className="wb-error-text" role="alert">
              {fieldErrors.public_base_url}
            </span>
          )}
        </label>

        <div className="wb-settings-form-actions">
          <Button type="submit" loading={saving} disabled={saving || clearing}>
            Save SMS settings
          </Button>
          {settings?.source === 'settings' && (
            <Button
              type="button"
              variant="ghost"
              loading={clearing}
              disabled={saving || clearing}
              onClick={() => void clearSaved()}
            >
              Clear saved settings
            </Button>
          )}
        </div>
        {message && (
          <p
            className={`wb-profile-message wb-profile-message-${message.tone}`}
            role={message.tone === 'error' ? 'alert' : 'status'}
            aria-live={message.tone === 'error' ? 'assertive' : 'polite'}
          >
            {message.text}
          </p>
        )}
      </form>
    </Card>
  )
}
