import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  describeDuration, describeEncryption, describeRetention, destinationLabel, requestInFlight, splitWarning,
} from '../src/lib/backups.ts'

test('retention summary', () => {
  assert.equal(describeRetention({ daily: 7, weekly: 4, monthly: 6, dry_run: false }), '7 daily · 4 weekly · 6 monthly')
  assert.equal(describeRetention({ daily: 7, weekly: 0, monthly: 0, dry_run: true }), '7 daily (dry run: nothing is deleted)')
  assert.match(describeRetention({ daily: 0, weekly: 0, monthly: 0, dry_run: false }), /Keep everything/)
  assert.equal(describeRetention(undefined), '—')
})

test('an unencrypted destination is flagged red', () => {
  assert.equal(describeEncryption('none').tone, 'red')
  assert.equal(describeEncryption('age-x25519').tone, 'green')
  assert.equal(describeEncryption(undefined).tone, 'grey')
})

test('durations', () => {
  assert.equal(describeDuration(null), '')
  assert.equal(describeDuration(450), '450 ms')
  assert.equal(describeDuration(12_400), '12s')
  assert.equal(describeDuration(125_000), '2m 5s')
})

test('request in flight and labels', () => {
  assert.equal(requestInFlight({ request: { status: 'pending' } }), true)
  assert.equal(requestInFlight({ request: { status: 'done' } }), false)
  assert.equal(requestInFlight({ request: null }), false)
  assert.equal(destinationLabel('s3'), 'S3')
})

test('warnings expose the command to run', () => {
  assert.equal(splitWarning('No backup has been recorded. Enable the scheduled backup service (docker compose --profile backup up -d) or run ./scripts/backup.sh daily.').command, 'docker compose --profile backup up -d')
  assert.equal(splitWarning('The backup service has stopped reporting. Check: docker compose --profile backup ps backup').command, 'docker compose --profile backup ps backup')
  assert.equal(splitWarning('Run ./scripts/backup.sh now').command, './scripts/backup.sh')
  assert.equal(splitWarning('The last successful backup is more than 36 hours old.').command, undefined)
})

import { credsBindingChanged, cronToDaily, dailyToCron, validateForm, parseRecipients } from '../src/lib/backups.ts'

test('daily time <-> cron', () => {
  assert.equal(cronToDaily('15 3 * * *'), '03:15')
  assert.equal(cronToDaily('0 */2 * * *'), null)
  assert.equal(cronToDaily('61 3 * * *'), null)
  assert.equal(dailyToCron('03:15'), '15 3 * * *')
  assert.equal(dailyToCron('25:00'), null)
})

const base = {
  s3_enabled: true, endpoint: '', region: '', bucket: 'my-bucket', prefix: 'openfamily', path_style: false, storage_class: '',
  insecure: false, allow_private: false, local_enabled: false, age_recipients: [], schedule: '15 3 * * *', timezone: 'UTC',
  keep_daily: 7, keep_weekly: 4, keep_monthly: 6, stale_hours: 36,
}

test('client validation mirrors the server rules', () => {
  assert.deepEqual(validateForm(base, new Set()), {})
  assert.ok(validateForm({ ...base, bucket: 'X' }, new Set()).bucket)
  assert.ok(validateForm({ ...base, endpoint: 'http://minio:9000' }, new Set()).endpoint)
  assert.deepEqual(validateForm({ ...base, endpoint: 'http://minio:9000', insecure: true }, new Set()), {})
  assert.ok(validateForm({ ...base, endpoint: 'https://u:p@host' }, new Set()).endpoint)
  assert.match(validateForm({ ...base, age_recipients: ['AGE-SECRET-KEY-1ABC'] }, new Set()).age_recipients, /PRIVATE/)
  assert.ok(validateForm({ ...base, age_recipients: ['nope'] }, new Set()).age_recipients)
  assert.ok(validateForm({ ...base, schedule: 'daily' }, new Set()).schedule)
  assert.ok(validateForm({ ...base, keep_daily: -1 }, new Set()).keep_daily)
  // Pinned fields are not validated client-side (they cannot be edited).
  assert.deepEqual(validateForm({ ...base, bucket: 'X' }, new Set(['bucket'])), {})
  assert.deepEqual(parseRecipients('a, b\nc'), ['a', 'b', 'c'])
})

test('changing the destination requires re-entering credentials', () => {
  const a = { endpoint: 'https://s3.example.com/', insecure: false, allow_private: false, region: 'eu' }
  assert.equal(credsBindingChanged(a, { ...a, endpoint: 'HTTPS://s3.example.com' }), false)
  assert.equal(credsBindingChanged(a, { ...a, endpoint: 'https://evil.example' }), true)
  assert.equal(credsBindingChanged(a, { ...a, insecure: true }), true)
  assert.equal(credsBindingChanged(a, { ...a, allow_private: true }), true)
  assert.equal(credsBindingChanged(a, { ...a, region: 'us' }), true)
})
