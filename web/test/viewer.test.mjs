import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ed25519 } from '@noble/curves/ed25519.js'
import * as c from '../src/e2ee/core.ts'
import * as vw from '../src/e2ee/viewer.ts'
import * as ks from '../src/e2ee/keystore.ts'
import { verifyLogSlice, verifyRegistration, syncLog, syncLogFull, authorizeWrap, authorizeSender, findDevice } from '../src/e2ee/verify.ts'
import { World, CIRCLE, USER_A, deviceRecord, phone } from './world.mjs'

const NOW = 1_700_000_100_000
const USER_B = '22222222-2222-4222-8222-222222222222'

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
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW, () => rep.logIndex)
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
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW, () => rep.logIndex)
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
  const rx2 = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep2.state, () => NOW, () => rep2.logIndex)
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
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => state, () => NOW, () => rep.logIndex)
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
  assert.equal(ok.head.seq, s.w.log.length)
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
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW, () => rep.logIndex)
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

// ---------------------------------------------------------------- fail-closed authorization

async function synced() {
  const s = await setup()
  await pair(s)
  const d = deps(s)
  const rep = await vw.syncCircle(d, CIRCLE)
  assert.equal(rep.newKeys, 1)
  return { s, d, rep }
}

const wrapFor = (s) => s.w.wraps.find((x) => x.recipient_device_id === s.sub.deviceId)

test('authorizeWrap baseline accepts the honest wrap', async () => {
  const { s, rep } = await synced()
  assert.equal(authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, wrapFor(s), rep.state.epochs[0]), null)
})

test('authorizeWrap fails closed', async () => {
  const { s, rep } = await synced()
  const clone = () => structuredClone(rep.state)
  const w0 = wrapFor(s)
  const rec0 = rep.state.epochs[0]
  const cases = {
    'no log index': () => authorizeWrap(null, rep.state.members, CIRCLE, USER_A, w0, rec0),
    'no epoch record': () => authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, w0, undefined),
    'publisher missing from state': () => {
      const st = clone()
      for (const m of st.members) m.devices = m.devices.filter((d) => d.device_id !== s.w.A.deviceId)
      return authorizeWrap(rep.logIndex, st.members, CIRCLE, USER_A, w0, rec0)
    },
    'publisher key differs': () => authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, w0, { ...rec0, publisher_ed25519_pub: c.b64(s.w.B.ed) }),
    'publisher revoked in state': () => {
      const st = clone(); findDevice(st.members, s.w.A.deviceId).dev.revoked_at = '2026-01-01T00:00:00Z'
      return authorizeWrap(rep.logIndex, st.members, CIRCLE, USER_A, w0, rec0)
    },
    'publisher not approved': () => {
      const st = clone(); findDevice(st.members, s.w.A.deviceId).dev.approved = false
      return authorizeWrap(rep.logIndex, st.members, CIRCLE, USER_A, w0, rec0)
    },
    'publisher not admin': () => {
      const st = clone(); findDevice(st.members, s.w.A.deviceId).member.role = 'member'
      return authorizeWrap(rep.logIndex, st.members, CIRCLE, USER_A, w0, rec0)
    },
    'epoch record not in log': () => authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, w0, { ...rec0, key_commitment: c.b64(new Uint8Array(32)) }),
    'wrapper missing': () => authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, { ...w0, wrapper_device_id: 'ffffffff-ffff-4fff-8fff-ffffffffffff' }, rec0),
    'wrapper wrong key': () => authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, { ...w0, wrapper_ed25519_pub: c.b64(s.w.B.ed) }, rec0),
    'wrapper is another member': () => authorizeWrap(rep.logIndex, rep.state.members, CIRCLE, USER_A, { ...w0, wrapper_device_id: s.w.B.deviceId, wrapper_ed25519_pub: c.b64(s.w.B.ed) }, rec0),
    'wrapper registration forged': () => {
      const st = clone(); findDevice(st.members, s.w.A.deviceId).dev.registration_signature = c.b64(new Uint8Array(64))
      return authorizeWrap(rep.logIndex, st.members, CIRCLE, USER_A, w0, rec0)
    },
  }
  for (const [name, f] of Object.entries(cases)) assert.notEqual(f(), null, name)
})

test('a wrapper that is not in the verified log is refused; revoked in the log too', async () => {
  const { s, d, rep } = await synced()
  const phone2 = phone(5, USER_A, '55555555-5555-4555-8555-555555555555')
  const rec = deviceRecord(phone2, { actor: s.w.A }) // validly vouched but never logged
  s.w.devices.push(rec)
  s.w.keys.get(1)
  const aad = c.wrapAad(CIRCLE, 1, s.sub.deviceId, phone2.deviceId)
  const blob = c.wrapWithRandomness(s.w.keys.get(1), s.sub.x, aad, c.randomBytes(32), c.randomBytes(24))
  const sig = ed25519.sign(c.wrapSigMessage(CIRCLE, 1, s.sub.deviceId, phone2.deviceId, blob), phone2.edSeed)
  const w2 = { epoch: 1, recipient_device_id: s.sub.deviceId, wrapper_device_id: phone2.deviceId, wrapper_ed25519_pub: c.b64(phone2.ed), wrapped_key: c.b64(blob), signature: c.b64(sig) }
  const rep2 = await vw.syncCircle(d, CIRCLE)
  assert.match(authorizeWrap(rep2.logIndex, rep2.state.members, CIRCLE, USER_A, w2, rep2.state.epochs[0]), /not in the verified log/)
  // The log revokes the publisher although the state still lists it.
  s.w.appendLog(3, USER_A, s.w.A, { subject: s.w.A.deviceId, ref: c.fingerprint(s.w.A.ed, s.w.A.x), sig: ed25519.sign(c.logActionMessage(3, USER_A, s.w.A.deviceId, { subjectId: s.w.A.deviceId, ref: c.fingerprint(s.w.A.ed, s.w.A.x) }), s.w.A.edSeed), msg: c.logActionMessage(3, USER_A, s.w.A.deviceId, { subjectId: s.w.A.deviceId, ref: c.fingerprint(s.w.A.ed, s.w.A.x) }) })
  const rep3 = await vw.syncCircle(d, CIRCLE)
  assert.match(authorizeWrap(rep3.logIndex, rep3.state.members, CIRCLE, USER_A, wrapFor(s), rep3.state.epochs[0]), /revoked/)
  void rep
})

test('syncCircle never stores a key whose wrapper or publisher is missing from the state', async () => {
  const s = await setup()
  await pair(s)
  for (const m of [s.w]) m.devices = m.devices.filter((x) => x.device_id !== s.w.A.deviceId) // publisher vanishes from the served state
  const rep = await vw.syncCircle(deps(s), CIRCLE)
  assert.equal(rep.newKeys, 0)
  assert.equal(rep.rejectedWraps, 1)
  assert.deepEqual(rep.heldEpochs, [])
})

test('item from a device listed under another user is dropped; userId comes from the device', async () => {
  const { s, d, rep } = await synced()
  const st = structuredClone(rep.state)
  // The server files Bob's phone under Alex.
  const bobDev = findDevice(st.members, s.w.B.deviceId)
  bobDev.member.devices = bobDev.member.devices.filter((x) => x !== bobDev.dev)
  st.members[0].devices.push(bobDev.dev)
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => st, () => NOW, () => rep.logIndex)
  const res = await rx.handle(s.w.seal(s.w.B, 1, 'fix', 1, NOW - 1000, { lat: 1, lon: 2 }))
  assert.equal(res.type, 'dropped')
  assert.match(res.reason, /another user/)
  // Honest placement: the point is attributed to the device's own (signed) user.
  const rx2 = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep.state, () => NOW, () => rep.logIndex)
  const ok = await rx2.handle(s.w.seal(s.w.B, 1, 'fix', 2, NOW - 900, { lat: 1, lon: 2 }))
  assert.equal(ok.points[0].userId, USER_B)
})

test('sender not in the verified log is deferred, never accepted; revoked sender dropped', async () => {
  const { s, d, rep } = await synced()
  const ghost = phone(6, USER_B, '66666666-6666-4666-8666-666666666666')
  s.w.devices.push(deviceRecord(ghost, { actor: s.w.B })) // valid vouching, but no log entry
  const rep2 = await vw.syncCircle(d, CIRCLE)
  const rx = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep2.state, () => NOW, () => rep2.logIndex)
  assert.equal((await rx.handle(s.w.seal(ghost, 1, 'fix', 1, NOW - 500, { lat: 1, lon: 1 }))).type, 'deferred')
  // No log index at all: fail closed.
  const rx0 = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => rep2.state, () => NOW)
  assert.equal((await rx0.handle(s.w.seal(s.w.B, 1, 'fix', 5, NOW - 500, { lat: 1, lon: 1 }))).type, 'dropped')
  // revoked_at set in the state
  const st = structuredClone(rep.state)
  findDevice(st.members, s.w.B.deviceId).dev.revoked_at = '2026-01-01T00:00:00Z'
  const rx1 = new vw.Receiver(CIRCLE, (e) => d.vault.getCircleKey(CIRCLE, e), () => st, () => NOW, () => rep.logIndex)
  assert.equal((await rx1.handle(s.w.seal(s.w.B, 1, 'fix', 6, NOW - 500, { lat: 1, lon: 1 }))).type, 'dropped')
})

test('registration verdicts cannot be poisoned: same device_id and signature, different covered field', async () => {
  const { s, rep } = await synced()
  const good = findDevice(rep.state.members, s.w.B.deviceId).dev
  assert.equal(authorizeSender(rep.logIndex, rep.state.members, findDevice(rep.state.members, s.w.B.deviceId)), null)
  const forged = structuredClone(rep.state.members)
  const f = findDevice(forged, s.w.B.deviceId)
  f.dev.x25519_pub = c.b64(s.w.A.x) // same device_id + registration_signature, another covered field
  assert.notEqual(authorizeSender(rep.logIndex, rep.state.members, f), null)
  assert.equal(verifyRegistration(good), true)
  assert.equal(verifyRegistration(f.dev), false)
  // Order independence.
  assert.notEqual(authorizeSender(rep.logIndex, rep.state.members, f), null)
  assert.equal(authorizeSender(rep.logIndex, rep.state.members, findDevice(rep.state.members, s.w.B.deviceId)), null)
})

test('full-log sync keeps the pin rules: fork and rollback with a pinned head', async () => {
  const { s } = await synced()
  const fetchPage = async (after) => ({ entries: s.w.log.filter((e) => e.seq > after).slice(0, 2), head: { seq: s.w.log.length, hash: s.w.log.at(-1).entry_hash } })
  assert.ok((await syncLogFull(null, fetchPage)).check.ok)
  assert.equal((await syncLogFull({ seq: 2, hash: '11'.repeat(32) }, fetchPage)).check.problem, 'fork')
  assert.equal((await syncLogFull({ seq: 99, hash: '11'.repeat(32) }, fetchPage)).check.problem, 'rollback')
})

// ---------------------------------------------------------------- chain walk (key binding, revoke order)

async function indexOfWorld(w) {
  const r = await syncLogFull(null, async (after) => ({
    entries: w.log.filter((e) => e.seq > after).slice(0, 500),
    head: { seq: w.log.length, hash: w.log.at(-1).entry_hash },
  }))
  return r
}
const membersOf = (w, ...recs) => [{ user_id: USER_A, name: 'Alex', role: 'admin', devices: recs.map((r) => { const { _msg, _sig, _actor, ...x } = r; return x }) }]
const asFound = (m, d) => ({ dev: m[0].devices.find((x) => x.device_id === d.device_id), member: m[0] })
function revokeEntry(w, target, by) {
  const fp = c.fingerprint(target.ed, target.x)
  const msg = c.logActionMessage(3, USER_A, by.deviceId, { subjectId: target.deviceId, ref: fp })
  w.appendLog(3, USER_A, by, { subject: target.deviceId, ref: fp, sig: ed25519.sign(msg, by.edSeed), msg })
}

test('chain walk: real flows (root phone, second phone, viewer vouched by a phone) are accepted', async () => {
  const w = new World()
  const a = w.register(w.A, { action: 1 })
  const p2s = phone(3, USER_A, '33333333-3333-4333-8333-333333333333')
  const p2 = w.register(p2s, { actor: w.A })
  const vs = phone(4, USER_A, '44444444-4444-4444-8444-444444444444')
  const v = w.register(vs, { actor: p2s, kind: 'web' })
  const { check, index } = await indexOfWorld(w)
  assert.ok(check.ok)
  const m = membersOf(w, a, p2, v)
  for (const d of [a, p2, v]) assert.equal(authorizeSender(index, m, asFound(m, d)), null)
})

test('chain walk: a second entry for a device signed with another key makes the whole log untrusted', async () => {
  const w = new World()
  w.register(w.A, { action: 1 })
  const evil = phone(0xee, USER_A, w.A.deviceId) // same device id, other key
  const x = phone(5, USER_A, '55555555-5555-4555-8555-555555555555')
  const fp = c.fingerprint(x.ed, x.x)
  const msg = c.logActionMessage(1, USER_A, w.A.deviceId, { subjectId: x.deviceId, ref: fp })
  w.appendLog(1, USER_A, evil, { subject: x.deviceId, ref: fp, sig: ed25519.sign(msg, evil.edSeed), msg })
  const r = await indexOfWorld(w)
  assert.equal(r.check.ok, false)
  assert.equal(r.check.problem, 'malformed')
})

test('chain walk: voucher id with a key the state does not list is refused', async () => {
  const w = new World()
  const a = w.register(w.A, { action: 1 })
  const p2s = phone(3, USER_A, '33333333-3333-4333-8333-333333333333')
  const p2 = w.register(p2s, { actor: w.A }) // listed with its real key, never signs afterwards
  const evil = phone(0xee, USER_A, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')
  const xs = phone(5, USER_A, '55555555-5555-4555-8555-555555555555')
  // X claims to be vouched by p2's id but with the attacker's key (valid signature, logged).
  const forged = deviceRecord(xs, { actor: { ...evil, deviceId: p2s.deviceId } })
  w.devices.push(forged)
  w.appendLog(1, USER_A, { ...evil, deviceId: p2s.deviceId }, { subject: xs.deviceId, ref: c.unhex(forged.fingerprint), sig: forged._sig, msg: forged._msg })
  const { check, index } = await indexOfWorld(w)
  assert.ok(check.ok) // p2 only signs once, so the log alone cannot tell
  assert.ok(verifyRegistration(forged))
  const m = membersOf(w, a, p2, forged)
  assert.notEqual(authorizeSender(index, m, asFound(m, forged)), null)
  assert.equal(index.chainLogged(forged, []), false) // and without the state: p2's own chain does not support that key
})

test('chain walk: root whose claimed key differs from the logged one is refused', async () => {
  const w = new World()
  const a = w.register(w.A, { action: 1 })
  const { index } = await indexOfWorld(w)
  const other = phone(0x42, USER_A, 'abababab-abab-4aba-8aba-abababababab')
  const bad = { ...a, registered_by_ed25519_pub: c.b64(other.ed) }
  assert.equal(index.chainLogged(bad, []), false)
  const bad2 = { ...a, ed25519_pub: c.b64(other.ed) }
  assert.equal(index.chainLogged(bad2, []), false)
})

test('chain walk: registration before the voucher revoke stays valid, after it is refused', async () => {
  const w = new World()
  w.register(w.A, { action: 1 })
  const p2s = phone(3, USER_A, '33333333-3333-4333-8333-333333333333')
  const p2 = w.register(p2s, { actor: w.A })
  revokeEntry(w, w.A, w.A) // the first phone is revoked AFTER p2 was registered by it
  const late = phone(6, USER_A, '66666666-6666-4666-8666-666666666666')
  const lateRec = w.register(late, { actor: w.A }) // registered AFTER the revoke by the revoked key
  const { check, index } = await indexOfWorld(w)
  assert.ok(check.ok)
  const m = membersOf(w, p2, lateRec)
  assert.equal(authorizeSender(index, m, asFound(m, p2)), null)
  assert.match(authorizeSender(index, m, asFound(m, lateRec)), /not in the verified log/)
  // A chain through a log-revoked middle voucher.
  const w2 = new World()
  w2.register(w2.A, { action: 1 })
  const midS = phone(3, USER_A, '33333333-3333-4333-8333-333333333333')
  w2.register(midS, { actor: w2.A })
  revokeEntry(w2, midS, w2.A)
  const deepS = phone(4, USER_A, '44444444-4444-4444-8444-444444444444')
  const deep = w2.register(deepS, { actor: midS })
  const r2 = await indexOfWorld(w2)
  const m2 = membersOf(w2, deep)
  assert.notEqual(authorizeSender(r2.index, m2, asFound(m2, deep)), null)
})

test('a device revoked in the log is refused even if the state still lists it', async () => {
  const w = new World()
  w.register(w.A, { action: 1 })
  const p2s = phone(3, USER_A, '33333333-3333-4333-8333-333333333333')
  const p2 = w.register(p2s, { actor: w.A })
  revokeEntry(w, p2s, w.A)
  const { index } = await indexOfWorld(w)
  const m = membersOf(w, p2)
  assert.match(authorizeSender(index, m, asFound(m, p2)), /revoked/)
})

test('redacted entries are tolerated by the index but never count as proof of anything', async () => {
  const w = new World()
  const a = w.register(w.A, { action: 1 })
  const p2s = phone(3, USER_A, '33333333-3333-4333-8333-333333333333')
  const p2 = w.register(p2s, { actor: w.A })
  // A hostile server could redact a revoke; the client cannot see it (documented limit), but the
  // registration must still be positively present. Redacting the REGISTRATION itself denies trust.
  const red = structuredClone(w.log)
  red[1] = { seq: 2, prev_hash: red[1].prev_hash, entry_hash: red[1].entry_hash, redacted: true }
  const r = await syncLogFull(null, async (after) => ({ entries: red.filter((e) => e.seq > after), head: { seq: red.length, hash: red.at(-1).entry_hash } }))
  assert.ok(r.check.ok)
  const m = membersOf(w, a, p2)
  assert.notEqual(authorizeSender(r.index, m, asFound(m, p2)), null)
})
