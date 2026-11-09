import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ed25519 } from '@noble/curves/ed25519.js'
import * as c from '../src/e2ee/core.ts'
import * as vw from '../src/e2ee/viewer.ts'
import * as av from '../src/e2ee/accountVault.ts'
import { World, CIRCLE, USER_A, USER_B } from './world.mjs'

const NOW = 1_700_000_100_000
const WEAK = { m: 8, t: 1 } // tests only
const PASS = 'orbit lantern pebble marmalade'

/** Phone A (admin) and B exist; a web key made from a known seed is registered, vouched by A, and wrapped epoch 1. */
function setup() {
  const w = new World()
  w.register(w.A, { action: 1 })
  w.register(w.B, { action: 1 })
  w.publishEpoch(1)
  const seed = c.randomBytes(32)
  const { edSeed, xSecret } = c.deriveIdentity(seed)
  const sub = { userId: USER_A, deviceId: w.V.deviceId, ed: c.edPublic(edSeed), x: c.xPublic(xSecret), edSeed }
  const fp = c.fingerprint(sub.ed, sub.x)
  const msg = c.logActionMessage(1, USER_A, w.A.deviceId, { subjectId: sub.deviceId, ref: fp })
  const asig = ed25519.sign(msg, w.A.edSeed)
  w.devices.push({
    device_id: sub.deviceId, user_id: USER_A, kind: 'web', ed25519_pub: c.b64(sub.ed), x25519_pub: c.b64(sub.x),
    fingerprint: c.hex(fp), signature: c.b64(ed25519.sign(c.bindingMessage(USER_A, sub.deviceId, sub.ed, sub.x), edSeed)),
    registered_by_device_id: w.A.deviceId, registered_by_ed25519_pub: c.b64(w.A.ed), registration_action: 1,
    registration_signature: c.b64(asig), approved: true, label: 'web',
  })
  w.appendLog(1, USER_A, w.A, { subject: sub.deviceId, ref: fp, sig: asig, msg })
  w.wrapTo(1, sub)
  const secret = { seed, approver: { deviceId: w.A.deviceId, edPub: c.b64(w.A.ed) }, name: 'Any browser', createdAt: NOW }
  return { w, sub, secret }
}

async function seal(s, pass = PASS) {
  return av.sealAccountVault({ userId: USER_A, deviceId: s.sub.deviceId, secret: s.secret, passphrase: pass, argon: WEAK, testing: true })
}

test('a sealed vault is opaque: no seed, passphrase or key bytes in the stored JSON', async () => {
  const s = setup()
  const { blob } = await seal(s)
  const json = JSON.stringify(blob)
  assert.ok(!json.includes(c.b64(s.secret.seed)))
  assert.ok(!json.includes(c.hex(s.secret.seed)))
  assert.ok(!json.includes(PASS))
  assert.ok(!json.includes(c.b64(s.sub.edSeed)))
  assert.equal(blob.user_id, USER_A)
  assert.equal(blob.device_id, s.sub.deviceId)
  assert.equal(blob.unlockers.length, 1)
  assert.equal(c.unb64(blob.unlockers[0].wrapped).length, 48)
})

test('any browser: open with the passphrase, check against the server record, sync and decrypt', async () => {
  const s = setup()
  const { blob } = await seal(s)
  // A different browser has nothing locally: only the blob from the server and the passphrase.
  const stored = JSON.parse(JSON.stringify(blob))
  const opened = await av.openAccountVault(stored, { passphrase: PASS, userId: USER_A })
  assert.deepEqual(opened.secret.seed, s.secret.seed)
  assert.deepEqual(opened.secret.approver, s.secret.approver)
  const record = s.w.devices.find((d) => d.device_id === opened.deviceId)
  const { ops, vault } = av.accountIdentity(opened.secret, opened.deviceId, record)
  const meta = { mode: 'session', userId: USER_A, deviceId: opened.deviceId, name: opened.secret.name, edPub: c.b64(ops.edPub), xPub: c.b64(ops.xPub), registered: true, createdAt: NOW, approver: opened.secret.approver }
  let pin = null
  const d = { http: s.w.http(), meta, ops, vault, getPin: async () => pin, setPin: async (h) => { pin = h } }
  const rep = await vw.syncCircle(d, CIRCLE)
  assert.equal(rep.newKeys, 1)
  assert.deepEqual(rep.heldEpochs, [1])
  assert.deepEqual(rep.memberTrustedEpochs, [], 'key came from our own anchored phone')
  s.w.seal(s.w.B, 1, 'fix', 1, NOW - 1000, { lat: 48.1, lon: 11.6 })
  const rx = new vw.Receiver(CIRCLE, (e) => vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW, () => rep.logIndex,
    () => ({ ownUserId: USER_A, anchor: opened.secret.approver }))
  const book = new vw.PositionBook()
  const r = await vw.pullItems(d.http, opened.deviceId, CIRCLE, rx, book)
  assert.equal(r.handled, 1)
  assert.equal(book.last.get(USER_B).lat, 48.1)
  // The pin is sealed for the server and survives a round trip; the server cannot move it back.
  const rec = av.sealPin(opened.dek, USER_A, opened.deviceId, pin)
  assert.deepEqual(av.openPin(opened.dek, USER_A, opened.deviceId, rec), pin)
})

test('wrong passphrase, another account, and tampering all fail closed', async () => {
  const s = setup()
  const { blob } = await seal(s)
  await assert.rejects(av.openAccountVault(blob, { passphrase: 'orbit lantern pebble marmalad', userId: USER_A }), /wrong vault passphrase/)
  await assert.rejects(av.openAccountVault(blob, { passphrase: PASS, userId: USER_B }), /another account/)
  // The server relabels the blob for another device id or user id: the AAD no longer matches.
  await assert.rejects(av.openAccountVault({ ...blob, device_id: '99999999-9999-4999-8999-999999999999' }, { passphrase: PASS, userId: USER_A }), /wrong vault passphrase/)
  await assert.rejects(av.openAccountVault({ ...blob, user_id: USER_B }, { passphrase: PASS, userId: USER_B }), /wrong vault passphrase/)
  // Changing the stretching parameters (to make guessing cheaper, say) breaks the unlocker.
  await assert.rejects(av.openAccountVault({ ...blob, unlockers: [{ ...blob.unlockers[0], t: 2 }] }, { passphrase: PASS, userId: USER_A }), /wrong vault passphrase/)
  // A flipped ciphertext byte in the payload.
  const ct = c.unb64(blob.sealed)
  ct[5] ^= 1
  await assert.rejects(av.openAccountVault({ ...blob, sealed: c.b64(ct) }, { passphrase: PASS, userId: USER_A }), /altered/)
  // Unknown format and absurd parameters are refused before any work.
  await assert.rejects(av.openAccountVault({ ...blob, v: 2 }, { passphrase: PASS, userId: USER_A }), /unknown format/)
  await assert.rejects(av.openAccountVault({ ...blob, unlockers: [{ ...blob.unlockers[0], m: 1 << 30 }] }, { passphrase: PASS, userId: USER_A }), /unsupported/)
})

test('the opened seed must be the key the server lists (active web key, same public keys)', async () => {
  const s = setup()
  const { blob } = await seal(s)
  const opened = await av.openAccountVault(blob, { passphrase: PASS, userId: USER_A })
  const record = s.w.devices.find((d) => d.device_id === opened.deviceId)
  assert.throws(() => av.accountIdentity(opened.secret, opened.deviceId, { ...record, revoked_at: '2026-11-09T00:00:00Z' }), /revoked/)
  assert.throws(() => av.accountIdentity(opened.secret, opened.deviceId, { ...record, kind: 'device' }), /not a web viewer/)
  assert.throws(() => av.accountIdentity(opened.secret, opened.deviceId, { ...record, ed25519_pub: c.b64(s.w.B.ed) }), /does not match/)
  assert.throws(() => av.accountIdentity(opened.secret, opened.deviceId, { ...record, device_id: s.w.B.deviceId }), /different viewer key/)
})

test('changing the vault passphrase keeps the same key; the old passphrase stops working', async () => {
  const s = setup()
  const { blob, dek } = await seal(s)
  const next = await av.changeVaultPassphrase(blob, dek, 'quiet harbour violet engine', { argon: WEAK, testing: true })
  assert.equal(next.sealed, blob.sealed)
  await assert.rejects(av.openAccountVault(next, { passphrase: PASS, userId: USER_A }), /wrong vault passphrase/)
  const o = await av.openAccountVault(next, { passphrase: 'quiet harbour violet engine', userId: USER_A })
  assert.deepEqual(o.secret.seed, s.secret.seed)
  await assert.rejects(av.changeVaultPassphrase(blob, c.randomBytes(32), 'quiet harbour violet engine', { argon: WEAK, testing: true }), /does not open/)
})

test('pin records: bound to account, device and seq; the newer pin always wins', async () => {
  const s = setup()
  const { dek } = await seal(s)
  const rec = av.sealPin(dek, USER_A, s.sub.deviceId, { seq: 7, hash: 'ab'.repeat(32) })
  assert.equal(av.openPin(dek, USER_B, s.sub.deviceId, rec), null)
  assert.equal(av.openPin(dek, USER_A, s.w.B.deviceId, rec), null)
  assert.equal(av.openPin(dek, USER_A, s.sub.deviceId, { ...rec, seq: 9 }), null, 'server cannot relabel the seq')
  assert.equal(av.openPin(c.randomBytes(32), USER_A, s.sub.deviceId, rec), null)
  const local = { seq: 12, hash: 'cd'.repeat(32) }
  assert.deepEqual(av.newerPin(local, av.openPin(dek, USER_A, s.sub.deviceId, rec)), local, 'an older server pin never moves a browser back')
  assert.deepEqual(av.newerPin(null, { seq: 7, hash: 'x' }), { seq: 7, hash: 'x' })
})

test('sealing policy: weak passphrases and weak parameters are refused outside tests', async () => {
  const s = setup()
  assert.match(av.passphraseProblem('short'), /at least 12/)
  assert.match(av.passphraseProblem('aaaaaaaaaaaaaaaa'), /different characters/)
  assert.match(av.passphraseProblem('alex@example.org rules', ['alex@example.org']), /email/)
  assert.equal(av.passphraseProblem(PASS), null)
  await assert.rejects(av.sealAccountVault({ userId: USER_A, deviceId: s.sub.deviceId, secret: s.secret, passphrase: 'short' }), /at least 12/)
  await assert.rejects(av.sealAccountVault({ userId: USER_A, deviceId: s.sub.deviceId, secret: s.secret, passphrase: PASS, argon: WEAK, pepper: c.randomBytes(32) }), /too weak/)
})

test('server pepper: required to open, bound in the AAD, and per account', async () => {
  const s = setup()
  const pepper = c.randomBytes(32)
  const { blob } = await av.sealAccountVault({ userId: USER_A, deviceId: s.sub.deviceId, secret: s.secret, passphrase: PASS, argon: WEAK, pepper, testing: true })
  assert.equal(blob.unlockers[0].pep, 1)
  await assert.rejects(av.openAccountVault(blob, { passphrase: PASS, userId: USER_A }), /pepper/)
  await assert.rejects(av.openAccountVault(blob, { passphrase: PASS, userId: USER_A, pepper: c.randomBytes(32) }), /wrong vault passphrase/)
  // The server cannot strip the pepper requirement by flipping the flag.
  await assert.rejects(av.openAccountVault({ ...blob, unlockers: [{ ...blob.unlockers[0], pep: 0 }] }, { passphrase: PASS, userId: USER_A, pepper }), /wrong vault passphrase/)
  const o = await av.openAccountVault(blob, { passphrase: PASS, userId: USER_A, pepper })
  assert.deepEqual(o.secret.seed, s.secret.seed)
  // Outside tests a pepper is mandatory.
  await assert.rejects(av.sealAccountVault({ userId: USER_A, deviceId: s.sub.deviceId, secret: s.secret, passphrase: PASS }), /pepper/)
})
