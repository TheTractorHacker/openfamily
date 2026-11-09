import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ed25519 } from '@noble/curves/ed25519.js'
import * as c from '../src/e2ee/core.ts'
import * as vw from '../src/e2ee/viewer.ts'
import * as aa from '../src/e2ee/accountAccess.ts'
import { idleExpired, IDLE_LOCK_MS } from '../src/lib/privateViewerCore.ts'
import { World, CIRCLE, USER_A, USER_B } from './world.mjs'

const NOW = 1_700_000_100_000
const WEAK = { m: 8, t: 1 }
const PW = 'account password 1'
const VP = 'orbit lantern pebble marmalade'

/** A fake server: World for the circle, plus the viewer-vault routes with the real rules that matter here. */
function server() {
  const w = new World()
  w.register(w.A, { action: 1 })
  w.register(w.B, { action: 1 })
  w.publishEpoch(1)
  const pepper = c.randomBytes(32)
  const st = { row: null, tickets: new Set(), unlocks: [], browsers: new Set(), notices: 0, puts: [] }
  const base = w.http()
  const http = {
    ...base,
    async get(path) {
      if (path === '/e2ee/viewer-vault') return { available: true, reason: '', exists: !!st.row, device_id: st.row?.blob.device_id }
      if (path === '/e2ee/me') return { devices: w.devices.filter((d) => d.user_id === USER_A) }
      return base.get(path)
    },
    async post(path, body) {
      if (path === '/e2ee/viewer-vault/unlock') {
        st.unlocks.push(body)
        if (body.password !== PW) throw new Error('password is incorrect')
        const t = c.b64(c.randomBytes(16))
        st.tickets.add(t)
        if (st.row && body.browser_id && !st.browsers.has(body.browser_id)) {
          st.browsers.add(body.browser_id)
          st.notices++
        }
        return { pepper: c.b64(pepper), ticket: t, blob: st.row?.blob ?? null, pin: st.row?.pin ?? null, device_id: st.row?.blob.device_id ?? null }
      }
      const r = await base.post(path, body)
      if (path === '/e2ee/devices') {
        // Store what the server would list for the key (vouched by phone A in this test).
        w.devices.push({ ...r, approved: true, label: 'web' })
        w.appendLog(1, USER_A, w.A, { subject: body.device_id, ref: c.unhex(r.fingerprint), sig: c.unb64(body.log_signature), msg: w._lastMsg })
      }
      return r
    },
    async put(path, body) {
      st.puts.push({ path, body })
      if (path === '/e2ee/viewer-vault') {
        if (!st.tickets.delete(body.ticket)) throw new Error('confirm your password again')
        assert.ok(!JSON.stringify(body).includes(VP), 'passphrase must never be sent')
        st.row = { blob: JSON.parse(JSON.stringify(body.blob)), pin: st.row?.pin ?? null }
        return { saved: true }
      }
      if (path === '/e2ee/viewer-vault/pin') {
        if (!st.row?.pin || body.pin.seq > st.row.pin.seq) st.row.pin = body.pin
        return { stored: true }
      }
      throw new Error('unexpected PUT ' + path)
    },
  }
  return { w, http, st, pepper }
}

/** Phone A approves a request code exactly like the app (cross-signature over the register action). */
function phoneApproves(w, code) {
  const req = JSON.parse(c.fromUtf8(c.unb64(code)))
  assert.equal(req.k, 'web')
  const ed = c.unb64(req.e)
  const x = c.unb64(req.x)
  assert.ok(c.edVerify(ed, c.bindingMessage(req.u, req.d, ed, x), c.unb64(req.b)))
  const msg = c.logActionMessage(1, USER_A, w.A.deviceId, { subjectId: req.d, ref: c.fingerprint(ed, x) })
  w._lastMsg = msg
  return c.b64urlPadded(c.utf8(JSON.stringify({ a: w.A.deviceId, s: c.b64(ed25519.sign(msg, w.A.edSeed)) })))
}

async function setUp(srv) {
  const key = aa.newAccountKey(USER_A, c.newUuid(), 'Web access')
  const code = await vw.buildRequestCode(key.meta, key.ops, 'web')
  const { anchor } = await vw.registerViewer(srv.http, key.meta, key.ops, vw.parseApproval(phoneApproves(srv.w, code)), 'web')
  key.meta.registered = true
  key.meta.approver = anchor
  const dek = await aa.saveAccountKey(srv.http, key, anchor, VP, { password: PW }, { browser: 'first-browser-0123456789', testArgon: WEAK })
  return { key, anchor, dek }
}

test('set up once, then unlock in a different browser and read a member', async () => {
  const srv = server()
  const { key } = await setUp(srv)
  assert.equal(srv.st.row.blob.device_id, key.meta.deviceId)
  // The phone shares the circle key with the new web key (its pending queue).
  srv.w.wrapTo(1, { userId: USER_A, deviceId: key.meta.deviceId, ed: key.ops.edPub, x: key.ops.xPub })

  // Browser two: nothing local. Password + vault passphrase only.
  const o = await aa.unlockAccountKey(srv.http, USER_A, VP, { password: PW }, 'second-browser-0123456789')
  assert.equal(o.meta.deviceId, key.meta.deviceId)
  assert.deepEqual(o.meta.approver, key.meta.approver)
  assert.equal(srv.st.notices, 1, 'the phones are told about the new browser')
  let pin = o.remotePin
  const d = { http: srv.http, meta: o.meta, ops: o.ops, vault: o.vault, getPin: async () => pin, setPin: async (h) => { pin = h } }
  const rep = await vw.syncCircle(d, CIRCLE)
  assert.deepEqual(rep.heldEpochs, [1])
  assert.deepEqual(rep.memberTrustedEpochs, [])
  srv.w.seal(srv.w.B, 1, 'fix', 1, NOW - 1000, { lat: 47.37, lon: 8.54 })
  const rx = new vw.Receiver(CIRCLE, (e) => o.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW, () => rep.logIndex,
    () => ({ ownUserId: USER_A, anchor: o.meta.approver }))
  const book = new vw.PositionBook()
  await vw.pullItems(srv.http, o.meta.deviceId, CIRCLE, rx, book)
  assert.equal(book.last.get(USER_B).lat, 47.37)

  // The sealed pin goes to the server; a third browser starts from it.
  await aa.pushPin(srv.http, o.dek, USER_A, o.meta.deviceId, pin)
  const o3 = await aa.unlockAccountKey(srv.http, USER_A, VP, { password: PW }, 'third-browser-0123456789')
  assert.deepEqual(o3.remotePin, pin)
  // Same browser again: no second notice.
  await aa.unlockAccountKey(srv.http, USER_A, VP, { password: PW }, 'third-browser-0123456789')
  assert.equal(srv.st.notices, 2)
  // Nothing sent to the server ever contained the passphrase or the seed.
  const wire = JSON.stringify([srv.st.puts, srv.st.unlocks])
  assert.ok(!wire.includes(VP))
  assert.ok(!wire.includes(c.b64(o3.dek)))
})

test('wrong passphrase, wrong password, account password as vault passphrase, revoked key', async () => {
  const srv = server()
  const { key } = await setUp(srv)
  await assert.rejects(aa.unlockAccountKey(srv.http, USER_A, 'not the vault passphrase', { password: PW }), /wrong vault passphrase/)
  await assert.rejects(aa.unlockAccountKey(srv.http, USER_A, VP, { password: 'nope' }), /password is incorrect/)
  await assert.rejects(aa.unlockAccountKey(srv.http, USER_B, VP, { password: PW }), /another account/)
  const k2 = aa.newAccountKey(USER_A, c.newUuid(), 'x')
  k2.meta.registered = true
  await assert.rejects(aa.saveAccountKey(srv.http, k2, key.meta.approver, PW, { password: PW }), /different from your account password/)
  await assert.rejects(aa.saveAccountKey(srv.http, k2, key.meta.approver, 'short', { password: PW }), /at least 12/)
  // The server marks the key revoked: the browser refuses to use it.
  srv.w.devices.find((x) => x.device_id === key.meta.deviceId).revoked_at = '2026-11-09T00:00:00Z'
  await assert.rejects(aa.unlockAccountKey(srv.http, USER_A, VP, { password: PW }), /revoked/)
})

test('change the vault passphrase: same key, old passphrase dead', async () => {
  const srv = server()
  const { key, dek } = await setUp(srv)
  await aa.changeAccountPassphrase(srv.http, USER_A, dek, 'quiet harbour violet engine', { password: PW }, { testArgon: WEAK })
  await assert.rejects(aa.unlockAccountKey(srv.http, USER_A, VP, { password: PW }), /wrong vault passphrase/)
  const o = await aa.unlockAccountKey(srv.http, USER_A, 'quiet harbour violet engine', { password: PW })
  assert.equal(o.meta.deviceId, key.meta.deviceId)
})

test('browser id is random, stable, and not secret; idle lock after 30 minutes', () => {
  const m = new Map()
  const store = { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) }
  const a = aa.browserId(store)
  assert.match(a, /^[A-Za-z0-9_-]{22,64}$/)
  assert.equal(aa.browserId(store), a)
  assert.notEqual(aa.browserId({ getItem: () => null, setItem: () => {} }), a)
  assert.equal(IDLE_LOCK_MS, 30 * 60 * 1000)
  assert.equal(idleExpired(1000 + IDLE_LOCK_MS - 1, 1000), false)
  assert.equal(idleExpired(1000 + IDLE_LOCK_MS, 1000), true)
})
