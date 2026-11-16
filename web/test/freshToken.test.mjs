import { test } from 'node:test'
import assert from 'node:assert/strict'

const store = new Map()
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => void store.set(k, String(v)),
  removeItem: (k) => void store.delete(k),
}
const { ensureFreshAccessToken, accessTokenStale } = await import('../src/lib/auth.ts')

const jwt = (exp) => `h.${Buffer.from(JSON.stringify({ exp })).toString('base64url')}.s`
const now = Math.floor(Date.now() / 1000)

test('accessTokenStale', () => {
  assert.equal(accessTokenStale(jwt(now + 600)), false)
  assert.equal(accessTokenStale(jwt(now - 5)), true)
  assert.equal(accessTokenStale('garbage'), true)
})

test('expired access token is refreshed before a WebSocket reconnect', async () => {
  store.set('wb_access_token', jwt(now - 10))
  store.set('wb_refresh_token', 'ref')
  const fresh = jwt(now + 900)
  let calls = 0
  const f = async () => {
    calls++
    return new Response(JSON.stringify({ access_token: fresh, refresh_token: 'ref2' }), { status: 200 })
  }
  const [a, b] = await Promise.all([ensureFreshAccessToken(f), ensureFreshAccessToken(f)])
  assert.equal(a, fresh)
  assert.equal(b, fresh)
  assert.equal(calls, 1)
  assert.equal(await ensureFreshAccessToken(f), fresh)
  assert.equal(calls, 1)
})
