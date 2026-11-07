import { test } from 'node:test'
import assert from 'node:assert/strict'
import { COMPAT_LABEL, COMPAT_TONE, describePolicy, isVersionInput, usersByStatus } from '../src/lib/compat.ts'

const policy = (over = {}) => ({
  min_supported_version: '0.16.0', latest_version: '0.20.0', window: ['0.16', '0.17', '0.18', '0.19', '0.20'],
  window_size: 5, source: 'window', env_min_supported: '', override: '', enforce_writes: false, ...over,
})

test('version input validation', () => {
  for (const ok of ['0.16', '0.16.0', 'v0.20.1', '0.21.0-rc1', ' 0.16.0 ']) assert.equal(isVersionInput(ok), true, ok)
  for (const bad of ['', 'abc', '1', '0.16.x', '0.16.0.1', '-1.0']) assert.equal(isVersionInput(bad), false, bad)
})

test('users per status', () => {
  const v = (status, users) => ({ app_version: '0.1.0', platform: 'android', users, last_seen: '', status })
  assert.deepEqual(usersByStatus([v('ok', 3), v('required', 2), v('required', 1), v('recommended', 4)]),
    { ok: 3, recommended: 4, required: 3, unknown: 0 })
})

test('policy description names where the minimum comes from', () => {
  assert.match(describePolicy(policy()), /Rolling window of the last 5 releases: 0\.16 to 0\.20/)
  assert.match(describePolicy(policy({ source: 'admin', min_supported_version: '0.12.0' })), /set by an admin/)
  assert.match(describePolicy(policy({ source: 'env' })), /MIN_SUPPORTED_APP_VERSION/)
})

test('every status has a label and a tone', () => {
  for (const s of ['ok', 'recommended', 'required', 'unknown']) {
    assert.ok(COMPAT_LABEL[s])
    assert.ok(COMPAT_TONE[s])
  }
})
