import { test } from 'node:test'
import assert from 'node:assert/strict'
import { lanesSummary } from '../src/lib/e2eeLanes.ts'

const circle = (over = {}) => ({
  id: 'c', name: 'Family', mode: 'private', epoch: 1, rekey_required: false, updated_at: null, members: 4, wrapped_keys: 4,
  server_assist: false, members_server_assisted: 0, members_phone_only: 4, legacy_trusted_server: false, ...over,
})

test('assistance off: everybody keeps data on their phone, even if a stale server count says otherwise', () => {
  const s = lanesSummary(circle({ members_server_assisted: 2, members_phone_only: 2 }))
  assert.equal(s.label, 'Phones only')
  assert.equal(s.tone, 'green')
  assert.equal(s.serverAssisted, 0)
  assert.equal(s.phoneOnly, 4)
  assert.match(s.policy, /ciphertext only/)
})

test('assistance on: counts and an honest sentence, no per-member data', () => {
  const s = lanesSummary(circle({ server_assist: true, members_server_assisted: 1, members_phone_only: 3 }))
  assert.equal(s.label, 'Server-assisted')
  assert.equal(s.tone, 'orange')
  assert.deepEqual([s.serverAssisted, s.phoneOnly], [1, 3])
  assert.match(s.policy, /1 member allows the server/)
  assert.match(s.policy, /3 members keep data on their phone/)
  assert.match(s.policy, /Each member decides for themselves/)
})

test('assistance on but nobody opted in is not shown as the server reading anything', () => {
  const s = lanesSummary(circle({ server_assist: true, members_server_assisted: 0, members_phone_only: 4 }))
  assert.equal(s.tone, 'grey')
  assert.match(s.policy, /0 members allow/)
})

test('legacy circle is flagged for upgrade', () => {
  const s = lanesSummary(circle({ legacy_trusted_server: true, server_assist: false, members_server_assisted: 4, members_phone_only: 0 }))
  assert.equal(s.label, 'Old trusted-server mode')
  assert.match(s.policy, /upgrade/)
})

test('a normal circle and an older server without lane fields', () => {
  assert.equal(lanesSummary(circle({ mode: 'off' })).label, 'Not private')
  const old = lanesSummary({ id: 'c', name: 'x', mode: 'private', epoch: 1, rekey_required: false, updated_at: null, members: 2, wrapped_keys: 2 })
  assert.equal(old.label, 'Phones only')
  assert.equal(old.serverAssisted, 0)
})

test('the summary object carries no control, only text and counts', () => {
  const keys = Object.keys(lanesSummary(circle())).sort()
  assert.deepEqual(keys, ['label', 'phoneOnly', 'policy', 'serverAssisted', 'tone'])
})
