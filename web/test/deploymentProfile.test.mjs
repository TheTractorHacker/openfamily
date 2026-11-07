import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  cloudWarnings,
  enrollCommands,
  profileSummary,
  qrText,
  serverProcessing,
  setupComplete,
  setupSteps,
  showSetupCard,
} from '../src/lib/deploymentProfile.ts'
import { qrSvg } from '../src/lib/qr.ts'

const base = {
  profile: '',
  effective: 'cloud',
  source: 'unset',
  recommended_lane: 'phone',
  token_configured: false,
  server_pinned: false,
  setup_dismissed: false,
  circles_with_server: 0,
  server_device: null,
  at_rest: { key_configured: false, protected_columns: ['sms_settings.auth_token'], locations_encrypted: false, disk_encryption_known: false },
  docs_path: '/docs/server-setup',
}

test('a fresh install shows the three-step checklist with nothing done', () => {
  const steps = setupSteps(base)
  assert.deepEqual(steps.map((s) => s.key), ['profile', 'approve', 'apps'])
  assert.deepEqual(steps.map((s) => s.done), [false, false, false])
  assert.equal(showSetupCard(base), true)
  assert.equal(showSetupCard(null), false)
})

test('steps complete from server state, not from clicks', () => {
  const s = { ...base, profile: 'home', effective: 'home', token_configured: true, server_pinned: true, circles_with_server: 1 }
  assert.equal(setupComplete(s), true)
  assert.equal(serverProcessing(s), true)
  assert.equal(showSetupCard(s), false)
  const half = { ...base, profile: 'cloud', token_configured: true, server_pinned: true }
  assert.deepEqual(setupSteps(half).map((x) => x.done), [true, true, false])
})

test('a dismissed checklist stays hidden', () => {
  assert.equal(showSetupCard({ ...base, setup_dismissed: true }), false)
})

test('unset reads as the careful side in the words shown', () => {
  assert.match(profileSummary('cloud', false), /careful|rented/)
  assert.match(profileSummary('cloud', true), /could read/)
  assert.match(profileSummary('home', true), /you own/)
})

test('cloud warnings name the missing protections, home shows none', () => {
  const w = cloudWarnings({ ...base, backups: { last_run_at: '', last_status: 'ok', last_encrypted: false } })
  assert.equal(w.length, 2)
  assert.deepEqual(cloudWarnings({ ...base, effective: 'home' }), [])
  assert.deepEqual(cloudWarnings({ ...base, at_rest: { ...base.at_rest, key_configured: true } }), [])
})

test('qr text matches the phones key screens and renders as svg', () => {
  assert.equal(qrText('12345 67890'), 'Orbitly server key\n12345 67890')
  const svg = qrSvg(qrText('12345 67890 12345 67890'))
  assert.match(svg, /^<svg/)
})

test('enroll commands carry the email and never a password', () => {
  const c = enrollCommands(' me@example.org ')
  assert.match(c.request, /--email me@example\.org/)
  assert.match(c.request, /read -rsp/)
  assert.doesNotMatch(c.request, /password=/i)
  assert.match(enrollCommands('').request, /you@example\.org/)
  assert.match(c.start, /up -d e2ee-server-device/)
})
