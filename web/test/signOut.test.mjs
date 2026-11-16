import { test } from 'node:test'
import assert from 'node:assert/strict'

const store = new Map()
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => void store.set(k, String(v)),
  removeItem: (k) => void store.delete(k),
}
const { signOut, isAuthenticated } = await import('../src/lib/auth.ts')

test('signOut revokes the current session server-side and clears storage', async () => {
  store.set('wb_access_token', 'acc')
  store.set('wb_refresh_token', 'ref')
  const calls = []
  const fetchStub = async (path, init) => {
    calls.push([init.method, path])
    if (path === '/auth/sessions/current') return new Response(JSON.stringify({ id: 'fam1' }), { status: 200 })
    return new Response(null, { status: 204 })
  }
  await signOut(fetchStub)
  assert.deepEqual(calls, [['POST', '/auth/sessions/current'], ['DELETE', '/auth/sessions/fam1']])
  assert.equal(isAuthenticated(), false)
})

test('signOut clears storage even when the server is unreachable', async () => {
  store.set('wb_access_token', 'acc')
  store.set('wb_refresh_token', 'ref')
  await signOut(async () => { throw new Error('offline') })
  assert.equal(isAuthenticated(), false)
})
