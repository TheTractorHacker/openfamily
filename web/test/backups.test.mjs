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
