import { test } from 'node:test'
import assert from 'node:assert/strict'
import { trustedDefaultBlocker, trustedDefaultCanToggle } from '../src/lib/trustedDefault.ts'

test('toggle is blocked until the token and a pinned server device exist', () => {
  assert.match(trustedDefaultBlocker({ token_configured: false, server_device_pinned: false }), /E2EE_SERVER_INGEST_TOKEN/)
  assert.match(trustedDefaultBlocker({ token_configured: true, server_device_pinned: false }), /pinned/)
  assert.equal(trustedDefaultBlocker({ token_configured: true, server_device_pinned: true }), null)
})

test('a stale ON setting can always be switched off', () => {
  assert.equal(trustedDefaultCanToggle({ trusted_server_default: true, token_configured: false, server_device_pinned: false }), true)
  assert.equal(trustedDefaultCanToggle({ trusted_server_default: false, token_configured: false, server_device_pinned: false }), false)
  assert.equal(trustedDefaultCanToggle({ trusted_server_default: false, token_configured: true, server_device_pinned: true }), true)
})
