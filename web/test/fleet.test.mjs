import { test } from 'node:test'
import assert from 'node:assert/strict'
import { bestVersion, deviceFindings, memberHealth, reportNote, summarize } from '../src/lib/fleet.ts'

const NOW = Date.parse('2026-03-10T15:00:00Z')
const ago = (h) => new Date(NOW - h * 3_600_000).toISOString()
const dev = (over = {}) => ({
  id: 'd1', platform: 'android', name: 'Pixel', app_version: '0.19.0', os_version: 'Android 14',
  last_seen: ago(0.1), push_registered: true, push_transport: 'direct', direct_seen_at: null,
  last_push_ok_at: ago(2), last_push_fail_at: null, battery_opt: 'unrestricted', outbox_pending: 0,
  loc_permission: 'always', notif_permission: 'granted', bg_service: true, diag_reported_at: ago(0.1), ...over,
})
const member = (devices, over = {}) => ({ user_id: 'u', name: 'N', email: 'n@x', last_report_at: ago(0.1), last_ws_at: null, in_private_circle: false, devices, ...over })

test('a fully healthy phone has no findings', () => {
  assert.deepEqual(deviceFindings(dev(), NOW), [])
  assert.equal(memberHealth(member([dev()]), NOW), 'ok')
})

test('stale or never-seen phones are not reporting', () => {
  assert.equal(memberHealth(member([dev({ last_seen: ago(30) })]), NOW), 'bad')
  assert.equal(memberHealth(member([dev({ last_seen: null })]), NOW), 'bad')
  assert.equal(memberHealth(member([dev({ last_seen: ago(6) })]), NOW), 'warn')
})

test('restricted battery and denied location are bad, while-in-use is a warning', () => {
  assert.equal(memberHealth(member([dev({ battery_opt: 'restricted' })]), NOW), 'bad')
  assert.equal(memberHealth(member([dev({ loc_permission: 'denied' })]), NOW), 'bad')
  assert.equal(memberHealth(member([dev({ loc_permission: 'while_in_use' })]), NOW), 'warn')
})

test('unreported fields from an older app are not treated as failures', () => {
  const old = dev({ battery_opt: 'unknown', loc_permission: 'unknown', notif_permission: 'unknown', bg_service: null, outbox_pending: null, diag_reported_at: null })
  assert.equal(memberHealth(member([old]), NOW), 'ok')
})

test('a member is as healthy as their best phone', () => {
  assert.equal(memberHealth(member([dev({ last_seen: ago(90) }), dev({ id: 'd2' })]), NOW), 'ok')
  assert.equal(memberHealth(member([]), NOW), 'unknown')
})

test('push failure after the last success is flagged, success after failure is not', () => {
  assert.ok(deviceFindings(dev({ last_push_fail_at: ago(1) }), NOW).some((f) => /push/i.test(f.text)))
  assert.ok(!deviceFindings(dev({ last_push_fail_at: ago(5), last_push_ok_at: ago(1) }), NOW).some((f) => /push/i.test(f.text)))
  assert.ok(deviceFindings(dev({ push_registered: false }), NOW).some((f) => /push/i.test(f.text)))
})

test('summary counts members, phones without push and queued points', () => {
  const s = summarize([member([dev({ outbox_pending: 7 })]), member([dev({ push_registered: false, last_seen: ago(40) })])], NOW)
  assert.equal(s.total, 2)
  assert.equal(s.ok, 1)
  assert.equal(s.bad, 1)
  assert.equal(s.noPush, 1)
  assert.equal(s.pendingPoints, 7)
})

test('a private-circle phone with a recent encrypted update is not quiet', () => {
  const quiet = dev({ last_seen: ago(30) })
  assert.equal(memberHealth(member([quiet], { in_private_circle: true, last_activity_at: ago(0.05) }), NOW), 'ok')
  assert.equal(memberHealth(member([quiet], { in_private_circle: false, last_activity_at: ago(0.05) }), NOW), 'bad')
})

test('app version falls back to what the server last saw when the device row is stale', () => {
  assert.equal(bestVersion(dev({ app_version: '0.1.0', client_version: '0.23.0' })), '0.23.0')
  assert.equal(bestVersion(dev({ app_version: '0.21.1', client_version: '0.23.0' })), '0.21.1')
  assert.equal(bestVersion(dev({ app_version: '', client_version: undefined })), 'Unknown')
})

test('missing health report is explained precisely', () => {
  assert.equal(reportNote(dev()), '')
  assert.match(reportNote(dev({ diag_reported_at: null, app_version: '0.23.0' })), /open the app/)
  assert.match(reportNote(dev({ diag_reported_at: null, app_version: '0.12.0' })), /older than/)
})
