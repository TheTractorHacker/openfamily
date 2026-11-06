// Runs the SAME cross-language vectors the Go and Dart tests use
// (backend/internal/e2ee/testdata/vectors.json) against the browser code.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { ed25519 } from '@noble/curves/ed25519.js'
import * as c from '../src/e2ee/core.ts'

const V = JSON.parse(readFileSync(new URL('../../backend/internal/e2ee/testdata/vectors.json', import.meta.url), 'utf8'))
const h = (u) => c.hex(u)
const x = (s) => c.unhex(s)

for (const name of ['identity_a', 'identity_b']) {
  test(`identity ${name}: derivation, fingerprint, digits, short, binding`, () => {
    const i = V[name]
    const { edSeed, xSecret } = c.deriveIdentity(x(i.Seed))
    assert.equal(h(edSeed), i.EdSeed)
    assert.equal(h(xSecret), i.XSecret)
    const ed = c.edPublic(edSeed)
    const xp = c.xPublic(xSecret)
    assert.equal(h(ed), i.EdPub)
    assert.equal(h(xp), i.XPub)
    const fp = c.fingerprint(ed, xp)
    assert.equal(h(fp), i.Fingerprint)
    assert.equal(c.digitGroups(fp), i.Digits)
    assert.equal(c.shortFingerprint(fp), i.Short)
    const msg = c.bindingMessage(i.UserID, i.DeviceID, ed, xp)
    assert.equal(h(ed25519.sign(msg, edSeed)), i.BindingSig)
    assert.ok(c.edVerify(ed, msg, x(i.BindingSig)))
  })
}

test('wrap: AAD, blob, signature message, signature, unwrap, commitment', async () => {
  const w = V.wrap_a_to_b
  const a = V.identity_a
  const b = V.identity_b
  const aad = c.wrapAad(V.circle_id, V.epoch, b.DeviceID, a.DeviceID)
  assert.equal(h(aad), w.AAD)
  const blob = c.wrapWithRandomness(x(w.CircleKey), x(b.XPub), aad, x(w.EphemeralSecret), x(w.Nonce))
  assert.equal(h(blob), w.Blob)
  const sm = c.wrapSigMessage(V.circle_id, V.epoch, b.DeviceID, a.DeviceID, blob)
  assert.equal(h(sm), w.SigMessage)
  assert.equal(h(ed25519.sign(sm, x(a.EdSeed))), w.Signature)
  const { x25519 } = await import('@noble/curves/ed25519.js')
  const key = await c.unwrap(blob, async (p) => x25519.getSharedSecret(x(b.XSecret), p), x(b.XPub), aad)
  assert.equal(h(key), w.CircleKey)
  assert.equal(h(c.keyCommitment(key, V.circle_id, V.epoch)), w.Commitment)
  // A wrong AAD (other wrapper) must not open.
  const bad = c.wrapAad(V.circle_id, V.epoch, b.DeviceID, b.DeviceID)
  await assert.rejects(c.unwrap(blob, async (p) => x25519.getSharedSecret(x(b.XSecret), p), x(b.XPub), bad))
})

test('seal / open payload', () => {
  const s = V.seal
  const key = x(V.wrap_a_to_b.CircleKey)
  const p = c.sealWithNonce(key, V.circle_id, V.epoch, V.identity_a.DeviceID, s.Purpose, x(s.Plaintext), x(s.Nonce))
  assert.equal(h(p), s.Payload)
  assert.equal(h(c.open(key, V.circle_id, V.identity_a.DeviceID, s.Purpose, p)), s.Plaintext)
  assert.throws(() => c.open(key, V.circle_id, V.identity_a.DeviceID, 'fix', p))
  assert.throws(() => c.open(key, V.circle_id, V.identity_b.DeviceID, s.Purpose, p))
})

test('log action, signature and chained entry hash', () => {
  const l = V.log_action
  const msg = c.logActionMessage(l.Action, l.UserID, l.ActorDeviceID, { subjectId: l.SubjectID, ref: x(l.Ref) })
  assert.equal(h(msg), l.Message)
  assert.equal(h(ed25519.sign(msg, x(V.identity_a.EdSeed))), l.Signature)
  assert.equal(h(c.logEntryHash(x(l.Prev), Number(l.Seq), msg, x(l.Signature))), l.EntryHash)
})

test('padding', () => {
  const p = V.padding
  assert.equal(h(c.pad(x(p.Plain))), p.Padded)
  assert.equal(h(c.unpad(x(p.Padded))), p.Plain)
  assert.throws(() => c.unpad(x(p.Padded.replace(/0{2}$/, '01'))))
})

test('item envelope: payload bytes, open, tamper cases', () => {
  const it = V.item
  const key = x(V.wrap_a_to_b.CircleKey)
  const a = V.identity_a
  const payload = c.sealItem(key, V.circle_id, V.epoch, a.DeviceID, x(a.EdSeed), it.Purpose, Number(it.Seq), Number(it.TsMs), x(it.Body), x(it.Nonce))
  assert.equal(h(payload), it.Payload)
  const o = c.openItem(key, V.circle_id, a.DeviceID, x(a.EdPub), it.Purpose, Number(it.Seq), payload)
  assert.equal(o.seq, 7)
  assert.equal(o.tsMs, 1700000000123)
  assert.equal(h(o.body), it.Body)
  assert.throws(() => c.openItem(key, V.circle_id, a.DeviceID, x(a.EdPub), it.Purpose, 8, payload), /seq/)
  assert.throws(() => c.openItem(key, V.circle_id, a.DeviceID, x(V.identity_b.EdPub), it.Purpose, 7, payload), /signature/)
  assert.throws(() => c.openItem(key, V.circle_id, V.identity_b.DeviceID, x(a.EdPub), it.Purpose, 7, payload))
  assert.throws(() => c.openItem(key, V.circle_id, a.DeviceID, x(a.EdPub), 'event', 7, payload))
  const t = payload.slice()
  t[40] ^= 1
  assert.throws(() => c.openItem(key, V.circle_id, a.DeviceID, x(a.EdPub), it.Purpose, 7, t))
})
