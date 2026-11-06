import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ed25519 } from '@noble/curves/ed25519.js'
import * as c from '../src/e2ee/core.ts'
import * as vw from '../src/e2ee/viewer.ts'
import * as ks from '../src/e2ee/keystore.ts'
import { verifyLogSlice, verifyRegistration, syncLog } from '../src/e2ee/verify.ts'
import { World, CIRCLE, USER_A, deviceRecord, phone } from './world.mjs'

const NOW = 1_700_000_100_000

/** Phones A (admin, root) and B (member, root) exist; the viewer is a web key cross-signed by A. */
async function setup({ mode = 'session' } = {}) {
  const w = new World()
  w.register(w.A, { action: 1 })
  w.register(w.B, { action: 1 })
  w.publishEpoch(1)
  const kv = new ks.MemoryKV()
  const id = await ks.createIdentity({ kv, mode, userId: USER_A, deviceId: w.V.deviceId, name: 'Kitchen laptop', passphrase: 'correct horse', argon: { m: 8, t: 1 } })
  // The viewer's keys are whatever the keystore generated; register those, vouched by phone A.
  const sub = { userId: USER_A, deviceId: w.V.deviceId, ed: id.ops.edPub, x: id.ops.xPub }
  const fp = c.fingerprint(sub.ed, sub.x)
  const msg = c.logActionMessage(1, USER_A, w.A.deviceId, { subjectId: sub.deviceId, ref: fp })
  const asig = ed25519.sign(msg, w.A.edSeed)
  return { w, kv, id, sub, fp, msg, asig }
}

async function pair(s) {
  // Request code -> phone verifies the binding -> approval code -> viewer registers.
  const code = await vw.buildRequestCode(s.id.meta, s.id.ops, 'web')
  const req = JSON.parse(c.fromUtf8(c.unb64(code)))
  assert.equal(req.k, 'web')
  assert.equal(req.n, 'Kitchen laptop')
  assert.ok(c.edVerify(c.unb64(req.e), c.bindingMessage(req.u, req.d, c.unb64(req.e), c.unb64(req.x)), c.unb64(req.b)))
  const approval = c.b64urlPadded(c.utf8(JSON.stringify({ a: s.w.A.deviceId, s: c.b64(s.asig) })))
  const parsed = vw.parseApproval(approval)
  assert.equal(parsed.actorDeviceId, s.w.A.deviceId)
  await vw.registerViewer(s.w.http(), s.id.meta, s.id.ops, parsed)
  const body = s.w.lastPost.body
  assert.equal(s.w.lastPost.path, '/e2ee/devices')
  assert.equal(body.kind, 'web')
  assert.equal(body.can_upload, false)
  assert.ok(!JSON.stringify(body).toLowerCase().includes('secret'))
  // Server side: add the key record and have phone A wrap the epoch key to it.
  s.w.devices.push({
    device_id: s.sub.deviceId, user_id: USER_A, kind: 'web', ed25519_pub: body.ed25519_pub, x25519_pub: body.x25519_pub,
    fingerprint: c.hex(s.fp), signature: body.signature, registered_by_device_id: s.w.A.deviceId,
    registered_by_ed25519_pub: c.b64(s.w.A.ed), registration_action: 1, registration_signature: body.log_signature, approved: true, label: 'web',
  })
  s.w.appendLog(1, USER_A, s.w.A, { subject: s.sub.deviceId, ref: s.fp, sig: s.asig, msg: s.msg })
  s.w.wrapTo(1, s.sub)
}

function deps(s) {
  let pin = null
  return {
    http: s.w.http(), meta: s.id.meta, ops: s.id.ops, vault: s.id.vault,
    getPin: async () => pin, setPin: async (h) => { pin = h },
  }
}

test('pairing request/approval codes and registration body', async () => {
  const s = await setup()
  await pair(s)
})

test('end to end: sync keys, pull, decrypt positions of a member', async () => {
  const s = await setup()
  await pair(s)
  const d = deps(s)
  const rep = await vw.syncCircle(d, CIRCLE)
  assert.equal(rep.newKeys, 1)
  assert.deepEqual(rep.heldEpochs, [1])
  assert.equal(rep.self?.kind, 'web')
  s.w.seal(s.w.B, 1, 'fix', 1, NOW - 5000, { lat: 52.5, lon: 13.4, acc: 8, bat: 80, mo: 'walk' })
  s.w.seal(s.w.B, 1, 'fix', 2, NOW - 1000, { lat: 52.51, lon: 13.41 })
  s.w.seal(s.w.B, 1, 'history', 3, NOW - 900, { pts: [[NOW - 5000, 52.5, 13.4, 8], [NOW - 8000, 52.49, 13.39]] })
  s.w.seal(s.w.B, 1, 'event', 4, NOW - 800, { k: 'place', a: 'enter', name: 'Home' })
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW)
  const book = new vw.PositionBook()
  const r = await vw.pullItems(d.http, s.sub.deviceId, CIRCLE, rx, book)
  assert.equal(r.handled, 4)
  const last = book.last.get('22222222-2222-4222-8222-222222222222')
  assert.equal(last.lat, 52.51)
  assert.equal(last.name, 'Bea')
  // Live fix at -5000 and the same point inside the history chunk collapse; older history point is kept.
  assert.equal(book.trail('22222222-2222-4222-8222-222222222222').length, 3)
  assert.equal(book.events[0].place, 'Home')
  assert.ok(s.w.requests.some((p) => p.includes('as_device=' + s.sub.deviceId)))
})

test('duplicates are ignored; forged, unapproved and renumbered items are dropped', async () => {
  const s = await setup()
  await pair(s)
  const d = deps(s)
  const rep = await vw.syncCircle(d, CIRCLE)
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW)
  const it = s.w.seal(s.w.B, 1, 'fix', 1, NOW - 1000, { lat: 1, lon: 2 })
  assert.equal((await rx.handle(it)).type, 'points')
  assert.equal((await rx.handle(it)).type, 'ignored')
  // Renumbered by the server.
  const re = { ...s.w.seal(s.w.B, 1, 'fix', 2, NOW - 900, { lat: 1, lon: 2 }) }
  re.seq = 9
  assert.equal((await rx.handle(re)).type, 'dropped')
  // A member who holds the circle key signs as phone B but with another key: bad signature.
  const evil = { ...s.w.B, edSeed: new Uint8Array(32).fill(5) }
  const forged = s.w.seal(evil, 1, 'fix', 3, NOW - 800, { lat: 3, lon: 4 })
  assert.equal((await rx.handle(forged)).type, 'dropped')
  // Future timestamp.
  assert.equal((await rx.handle(s.w.seal(s.w.B, 1, 'fix', 4, NOW + 3_600_000, { lat: 1, lon: 1 }))).type, 'dropped')
  // Bad coordinates.
  assert.equal((await rx.handle(s.w.seal(s.w.B, 1, 'fix', 5, NOW, { lat: 99, lon: 1 }))).type, 'dropped')
  // Sender whose key is not approved in this circle.
  s.w.devices.find((x) => x.device_id === s.w.B.deviceId).approved = false
  const rep2 = await vw.syncCircle(d, CIRCLE)
  const rx2 = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep2.state, () => NOW)
  assert.equal((await rx2.handle(s.w.seal(s.w.B, 1, 'fix', 6, NOW - 500, { lat: 1, lon: 1 }))).type, 'dropped')
  // Unknown sender is deferred, not trusted.
  const stranger = phone(7, '33333333-3333-4333-8333-333333333333', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')
  assert.equal((await rx.handle(s.w.seal(stranger, 1, 'fix', 1, NOW - 500, { lat: 1, lon: 1 }))).type, 'deferred')
})

test('epoch rotation: items of a new epoch are deferred until the wrap arrives; rollback refused', async () => {
  const s = await setup()
  await pair(s)
  const d = deps(s)
  let rep = await vw.syncCircle(d, CIRCLE)
  s.w.publishEpoch(2)
  const it2 = s.w.seal(s.w.B, 2, 'fix', 1, NOW - 1000, { lat: 5, lon: 6 })
  let state = rep.state
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => state, () => NOW)
  assert.equal((await rx.handle(it2)).type, 'deferred')
  s.w.wrapTo(2, s.sub)
  rep = await vw.syncCircle(d, CIRCLE)
  state = rep.state
  assert.deepEqual(rep.heldEpochs, [1, 2])
  assert.equal((await rx.handle(it2)).type, 'points')
  // Same device now goes back to epoch 1: refused as rollback.
  assert.equal((await rx.handle(s.w.seal(s.w.B, 1, 'fix', 2, NOW - 500, { lat: 1, lon: 1 }))).type, 'dropped')
})

test('a wrap whose key does not match the signed commitment is rejected', async () => {
  const s = await setup()
  await pair(s)
  // Publisher signed the commitment of a DIFFERENT key than the one wrapped.
  const w2 = new World()
  w2.register(w2.A); w2.register(w2.B)
  w2.publishEpoch(1, { commitmentOfOther: c.randomBytes(32) })
  const id = s.id
  w2.devices.push({ ...s.w.devices.find((x) => x.device_id === s.sub.deviceId) })
  w2.wrapTo(1, s.sub)
  const d = { http: w2.http(), meta: id.meta, ops: id.ops, vault: id.vault, getPin: async () => null, setPin: async () => {} }
  const rep = await vw.syncCircle(d, CIRCLE)
  assert.equal(rep.newKeys, 0)
  assert.equal(rep.rejectedWraps, 1)
})

test('a wrap signed by someone else than the named wrapper is rejected', async () => {
  const s = await setup()
  await pair(s)
  s.w.wraps = []
  s.w.wrapTo(1, s.sub)
  s.w.wraps[0].wrapper_ed25519_pub = c.b64(s.w.B.ed) // claims B's key signed it
  const rep = await vw.syncCircle(deps(s), CIRCLE)
  assert.equal(rep.newKeys, 0)
  assert.equal(rep.rejectedWraps, 1)
})

test('transparency log: tamper, rollback, fork and gap are detected; pin advances', async () => {
  const s = await setup()
  await pair(s)
  const d = deps(s)
  const ok = await vw.verifyAndPinLog(d)
  assert.equal(ok.seq, s.w.log.length)
  // Rollback: server shows a shorter log than the pin.
  const short = { ...s.w, log: s.w.log.slice(0, 2) }
  const dShort = { ...d, http: { get: async (p) => {
    const after = Number(new URL('http://x' + p).searchParams.get('after'))
    const entries = short.log.filter((e) => e.seq > after)
    const last = short.log[short.log.length - 1]
    return { entries, head: { seq: last.seq, hash: last.entry_hash } }
  } } }
  await assert.rejects(vw.verifyAndPinLog(dShort), (e) => e.problem === 'rollback')
  // Tampered signature.
  const bad = structuredClone(s.w.log)
  const sig = c.unb64(bad[1].signature); sig[3] ^= 1; bad[1].signature = c.b64(sig)
  const head = { seq: bad.length, hash: bad[bad.length - 1].entry_hash }
  assert.equal(verifyLogSlice(null, bad, head).problem, 'bad-signature')
  // Altered content with the chain left alone: hash mismatch or signature failure.
  const bad2 = structuredClone(s.w.log); bad2[0].epoch = 5
  assert.notEqual(verifyLogSlice(null, bad2, head).ok, true)
  // Fork: pinned entry replaced.
  const fork = structuredClone(s.w.log)
  const pin = { seq: 2, hash: '11'.repeat(32) }
  assert.equal(verifyLogSlice(pin, fork.slice(1), head).problem, 'fork')
  // Gap.
  assert.equal(verifyLogSlice(null, s.w.log.filter((e) => e.seq !== 2), head).problem, 'gap')
  // Wrong genesis.
  const g = structuredClone(s.w.log); g[0].prev_hash = '01'.repeat(32)
  assert.equal(verifyLogSlice(null, g, head).problem, 'broken-chain')
  // Redacted entries keep the chain checkable.
  const red = structuredClone(s.w.log); red[1] = { seq: 2, prev_hash: red[1].prev_hash, entry_hash: red[1].entry_hash, redacted: true }
  assert.ok(verifyLogSlice(null, red, head).ok)
  // Multi-page sync.
  const pages = await syncLog(null, async (after) => ({ entries: s.w.log.filter((e) => e.seq > after).slice(0, 2), head: { seq: s.w.log.length, hash: s.w.log.at(-1).entry_hash } }))
  assert.ok(pages.ok)
})

test('registration chain verification', async () => {
  const w = new World()
  const a = w.register(w.A, { action: 1 })
  const b = w.register(w.B, { actor: w.A, action: 1 })
  assert.ok(verifyRegistration(a))
  assert.ok(verifyRegistration(b))
  assert.ok(!verifyRegistration(deviceRecord(w.B, { tamper: true })))
  assert.ok(!verifyRegistration({ ...a, fingerprint: '00'.repeat(32) }))
  assert.ok(!verifyRegistration({ ...a, registered_by_ed25519_pub: b.ed25519_pub }))
})

test('revoked viewer: pull stops with DeviceRevokedError', async () => {
  const s = await setup()
  await pair(s)
  const d = deps(s)
  const rep = await vw.syncCircle(d, CIRCLE)
  s.w.revoked = true
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW)
  await assert.rejects(vw.pullItems(d.http, s.sub.deviceId, CIRCLE, rx, new vw.PositionBook()), vw.DeviceRevokedError)
})

test('self revoke body is signed by the viewer key', async () => {
  const s = await setup()
  await vw.revokeSelf(s.w.http(), s.id.meta, s.id.ops)
  const { path, body } = s.w.lastDelete
  assert.equal(path, '/e2ee/devices/' + s.sub.deviceId)
  const msg = c.logActionMessage(3, USER_A, s.sub.deviceId, { subjectId: s.sub.deviceId, ref: s.fp })
  assert.ok(c.edVerify(s.id.ops.edPub, msg, c.unb64(body.log_signature)))
})

test('keystore: device mode keeps private keys non-extractable and survives unlock', async () => {
  const kv = new ks.MemoryKV()
  const id = await ks.createIdentity({ kv, mode: 'device', userId: USER_A, deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'x' })
  const stored = await kv.get('identity:' + USER_A)
  await assert.rejects(crypto.subtle.exportKey('pkcs8', stored.edPriv))
  await assert.rejects(crypto.subtle.exportKey('raw', stored.xPriv))
  await assert.rejects(crypto.subtle.exportKey('raw', stored.aes))
  const msg = c.utf8('hello')
  assert.ok(c.edVerify(id.ops.edPub, msg, await id.ops.sign(msg)))
  // X25519 agreement with the ops equals a noble computation from the peer side.
  const { x25519 } = await import('@noble/curves/ed25519.js')
  const peerSk = c.randomBytes(32)
  const a = await id.ops.ecdh(x25519.getPublicKey(peerSk))
  assert.deepEqual(a, x25519.getSharedSecret(peerSk, id.ops.xPub))
  await id.vault.putCircleKey(CIRCLE, 1, new Uint8Array(32).fill(7))
  const again = await ks.unlockIdentity(kv, USER_A)
  assert.deepEqual(await again.vault.getCircleKey(CIRCLE, 1), new Uint8Array(32).fill(7))
  assert.deepEqual(await again.vault.heldEpochs(CIRCLE), [1])
  // The stored circle key is not plaintext.
  const raw = await kv.get(`ck:${USER_A}:${CIRCLE}:1`)
  assert.ok(!Buffer.from(raw).includes(Buffer.from(new Uint8Array(32).fill(7))))
})

test('keystore: passphrase mode needs the right passphrase and never stores the seed in clear', async () => {
  const kv = new ks.MemoryKV()
  const id = await ks.createIdentity({ kv, mode: 'passphrase', userId: USER_A, deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'x', passphrase: 'correct horse', argon: { m: 8, t: 1 } })
  await id.vault.putCircleKey(CIRCLE, 3, new Uint8Array(32).fill(9))
  await assert.rejects(ks.unlockIdentity(kv, USER_A, 'wrong passphrase'), /wrong passphrase/)
  await assert.rejects(ks.unlockIdentity(kv, USER_A), /passphrase required/)
  const ok = await ks.unlockIdentity(kv, USER_A, 'correct horse')
  assert.deepEqual(ok.ops.edPub, id.ops.edPub)
  assert.deepEqual(await ok.vault.getCircleKey(CIRCLE, 3), new Uint8Array(32).fill(9))
  const rec = await kv.get('identity:' + USER_A)
  assert.ok(!('edSeed' in rec) && !('seed' in rec))
  await assert.rejects(ks.createIdentity({ kv, mode: 'passphrase', userId: USER_A, deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'x', passphrase: 'short' }), /at least 8/)
  await ks.wipeIdentity(kv, USER_A)
  assert.equal(await ks.loadMeta(kv, USER_A), null)
  assert.deepEqual(await ok.vault.heldEpochs(CIRCLE), [])
})

test('keystore: session mode stores nothing', async () => {
  const kv = new ks.MemoryKV()
  const id = await ks.createIdentity({ kv, mode: 'session', userId: USER_A, deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'x' })
  await id.vault.putCircleKey(CIRCLE, 1, new Uint8Array(32).fill(1))
  assert.equal(kv.m.size, 0)
  assert.deepEqual(await id.vault.getCircleKey(CIRCLE, 1), new Uint8Array(32).fill(1))
})
