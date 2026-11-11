// The Dawarich status line: failing, retry time, last delivery.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { agoText, dawarichProblem, retryText } from '../src/lib/dawarichStatus.ts'

const now = Date.parse('2026-11-11T12:00:00Z')
const at = (secs) => new Date(now + secs * 1000).toISOString()

test('a healthy sync shows no problem', () => {
  assert.equal(dawarichProblem({ last_error: '', failures: 0, next_retry_at: null, last_ok_at: at(-60) }, now), null)
})

test('a failing sync says what failed, the retry time and the last delivery', () => {
  const text = dawarichProblem(
    { last_error: 'Dawarich answered 503', failures: 3, next_retry_at: at(8 * 60), last_ok_at: at(-2 * 3600) },
    now,
  )
  assert.match(text, /after 3 tries in a row/)
  assert.match(text, /Dawarich answered 503\./)
  assert.match(text, /Trying again in 8 minutes/)
  assert.match(text, /Last delivery: 2h ago\./)
})

test('first failure and nothing ever delivered', () => {
  const text = dawarichProblem({ last_error: 'boom', failures: 1, next_retry_at: at(120), last_ok_at: null }, now)
  assert.doesNotMatch(text, /tries in a row/)
  assert.match(text, /Last delivery: never\./)
})

test('retry text covers soon, past, minutes and hours', () => {
  assert.equal(retryText(null, now), 'soon')
  assert.equal(retryText(at(-30), now), 'on the next check')
  assert.equal(retryText(at(60), now), 'on the next check')
  assert.equal(retryText(at(60 * 60), now), 'in 1 hour')
  assert.equal(retryText(at(120), now), 'in 2 minutes')
  assert.equal(agoText(null, now), 'never')
})
