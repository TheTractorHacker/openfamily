// Settings cards for sign-in hygiene and member privacy defaults. Each shows
// its own saving / saved / error state and an "Unsaved changes" hint.

import React from 'react'
import { useUnsavedChanges } from '../lib/unsaved'
import {
  ApiError,
  getMemberDefaults,
  getSecuritySettings,
  putMemberDefaults,
  putSecuritySettings,
  type MemberDefaults,
  type SecuritySettings,
} from '../lib/api'
import { Button, Card } from '../components/primitives'

const errText = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : 'Request failed')

function Info({ children }: { children: React.ReactNode }) {
  return (
    <details className="wb-info">
      <summary aria-label="More information">i</summary>
      <div className="wb-info-body">{children}</div>
    </details>
  )
}

export function SessionSecurityCard() {
  const [saved, setSaved] = React.useState<SecuritySettings | null>(null)
  const [defaults, setDefaults] = React.useState<SecuritySettings | null>(null)
  const [form, setForm] = React.useState<SecuritySettings | null>(null)
  const [state, setState] = React.useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [error, setError] = React.useState<string | null>(null)

  React.useEffect(() => {
    let live = true
    getSecuritySettings()
      .then((r) => {
        if (!live) return
        setSaved(r.settings)
        setForm(r.settings)
        setDefaults(r.defaults)
      })
      .catch((e) => live && setError(errText(e)))
    return () => {
      live = false
    }
  }, [])

  const dirty = !!saved && !!form && (saved.session_idle_days !== form.session_idle_days || saved.max_sessions_per_user !== form.max_sessions_per_user)
  useUnsavedChanges(dirty, 'Sign-in sessions')
  const invalid = !!form && (form.session_idle_days < 1 || form.session_idle_days > 365 || form.max_sessions_per_user < 1 || form.max_sessions_per_user > 500)

  const save = async () => {
    if (!form) return
    setState('saving')
    setError(null)
    try {
      const r = await putSecuritySettings(form)
      setSaved(r.settings)
      setForm(r.settings)
      setState('saved')
    } catch (e) {
      setError(errText(e))
      setState('error')
    }
  }

  return (
    <Card>
      <h3 className="wb-settings-title">Sign-in sessions</h3>
      <p className="wb-settings-section-help">
        How long an unused sign-in lasts and how many one person can keep. Signing in again on the same phone replaces its old session.
      </p>
      {!form ? (
        <p className="wb-help">{error ?? 'Loading…'}</p>
      ) : (
        <div className="wb-settings-section wb-settings-section-flush">
          <label className="wb-field" htmlFor="sec-idle">
            <span className="wb-label">Sign out after no activity for (days) <Info>Apps refresh their sign-in every few minutes while in use. A sign-in nobody has used for this long is ended automatically (checked hourly). 1 to 365.</Info></span>
            <input id="sec-idle" className="wb-input" type="number" min={1} max={365} value={form.session_idle_days}
              onChange={(e) => { setForm({ ...form, session_idle_days: Number(e.target.value) }); setState('idle') }} />
            <span className="wb-help">Default {defaults?.session_idle_days ?? 14} days.</span>
          </label>
          <label className="wb-field" htmlFor="sec-max">
            <span className="wb-label">Most sessions per person <Info>When someone signs in beyond this number, their oldest sessions are signed out. 1 to 500.</Info></span>
            <input id="sec-max" className="wb-input" type="number" min={1} max={500} value={form.max_sessions_per_user}
              onChange={(e) => { setForm({ ...form, max_sessions_per_user: Number(e.target.value) }); setState('idle') }} />
            <span className="wb-help">Default {defaults?.max_sessions_per_user ?? 20}.</span>
          </label>
          <div className="wb-row">
            <Button loading={state === 'saving'} disabled={!dirty || invalid || state === 'saving'} onClick={() => void save()}>Save</Button>
            <Button variant="ghost" disabled={!defaults || state === 'saving'} onClick={() => { if (defaults) { setForm(defaults); setState('idle') } }}>Reset to default</Button>
            {dirty && <span className="wb-help" role="status">Unsaved changes</span>}
            {state === 'saved' && !dirty && <span className="wb-help" role="status">Saved.</span>}
          </div>
          {(invalid || error) && <p className="wb-error-text" role="alert">{invalid ? 'Use whole numbers inside the ranges shown.' : error}</p>}
        </div>
      )}
    </Card>
  )
}

export function MemberDefaultsCard() {
  const [saved, setSaved] = React.useState<MemberDefaults | null>(null)
  const [form, setForm] = React.useState<MemberDefaults | null>(null)
  const [missing, setMissing] = React.useState(false)
  const [state, setState] = React.useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [error, setError] = React.useState<string | null>(null)

  React.useEffect(() => {
    let live = true
    getMemberDefaults()
      .then((r) => { if (live) { setSaved(r); setForm(r) } })
      .catch((e) => {
        if (!live) return
        if (e instanceof ApiError && (e.status === 404 || e.status === 405)) setMissing(true)
        else setError(errText(e))
      })
    return () => { live = false }
  }, [])

  const dirty = !!saved && !!form && (saved.default_lane !== form.default_lane || saved.auto_apply !== form.auto_apply)
  useUnsavedChanges(dirty, 'Default for new members')
  const save = async () => {
    if (!form) return
    setState('saving')
    setError(null)
    try {
      const r = await putMemberDefaults(form)
      setSaved(r)
      setForm(r)
      setState('saved')
    } catch (e) {
      setError(errText(e))
      setState('error')
    }
  }

  return (
    <Card>
      <h3 className="wb-settings-title">Default for new members</h3>
      <p className="wb-settings-section-help">
        Who processes a new member’s location by default. Members can always change this for themselves.
      </p>
      {missing ? (
        <p className="wb-help" role="note">This server version does not have a member default yet. It appears here after the next update.</p>
      ) : !form ? (
        <p className="wb-help">{error ?? 'Loading…'}</p>
      ) : (
        <div className="wb-settings-section wb-settings-section-flush">
          <label className="wb-field" htmlFor="md-lane">
            <span className="wb-label">Default processing <Info>Server processing gives you maps, history and driving reports on this server. Phone-only keeps raw locations on the phone. Members can opt out.</Info></span>
            <select id="md-lane" className="wb-select" value={form.default_lane}
              onChange={(e) => { setForm({ ...form, default_lane: e.target.value as MemberDefaults['default_lane'] }); setState('idle') }}>
              <option value="server">Server processing (members can opt out)</option>
              <option value="phone">Phone only</option>
            </select>
          </label>
          <label className="wb-sess-days" htmlFor="md-auto">
            <input id="md-auto" type="checkbox" checked={form.auto_apply}
              onChange={(e) => { setForm({ ...form, auto_apply: e.target.checked }); setState('idle') }} />{' '}
            Apply automatically to members who have not chosen yet
          </label>
          <div className="wb-row">
            <Button loading={state === 'saving'} disabled={!dirty || state === 'saving'} onClick={() => void save()}>Save</Button>
            <Button variant="ghost" disabled={!saved || !dirty} onClick={() => { setForm(saved); setState('idle') }}>Discard</Button>
            {dirty && <span className="wb-help" role="status">Unsaved changes</span>}
            {state === 'saved' && !dirty && <span className="wb-help" role="status">Saved.</span>}
          </div>
          {error && <p className="wb-error-text" role="alert">{error}</p>}
        </div>
      )}
    </Card>
  )
}
