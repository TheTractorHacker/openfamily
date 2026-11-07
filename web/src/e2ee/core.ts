// Wire formats of the Orbitly end-to-end encryption (docs/design/E2EE.md),
// implemented in the browser. This file mirrors backend/internal/e2ee (Go) and
// app/lib/services/e2ee/e2ee_crypto.dart (Dart) byte for byte; the shared test
// vectors in backend/internal/e2ee/testdata/vectors.json are checked by
// web/test/vectors.test.mjs.
//
// Primitives come from the audited, dependency-free noble libraries (MIT):
// @noble/curves (Ed25519, X25519), @noble/ciphers (XChaCha20-Poly1305) and
// @noble/hashes (SHA-2, HKDF, Argon2id). No private key ever leaves this
// module's callers: functions take a KeyOps object, never raw secrets, except
// the in-memory fallback implementation.

import { ed25519, x25519 } from '@noble/curves/ed25519.js'
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js'
import { sha256, sha512 } from '@noble/hashes/sha2.js'
import { hkdf } from '@noble/hashes/hkdf.js'

export const PUB_LEN = 32
export const SIG_LEN = 64
export const KEY_LEN = 32
export const NONCE_LEN = 24
export const TAG_LEN = 16
export const WRAP_VERSION = 1
export const WRAP_BLOB_LEN = 1 + 32 + 24 + 32 + 16
export const MSG_VERSION = 1
export const ITEM_VERSION = 1
export const ZERO_UUID = '00000000-0000-0000-0000-000000000000'

export const ACT = {
  register: 1,
  rotate: 2,
  revoke: 3,
  recovery: 4,
  enable: 5,
  epoch: 6,
  disable: 7,
  reset: 8,
  approve: 9,
} as const

export class E2eeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'E2eeError'
  }
}

const enc = new TextEncoder()
export const utf8 = (s: string): Uint8Array => enc.encode(s)
export const fromUtf8 = (b: Uint8Array): string => new TextDecoder().decode(b)

export function cat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

export function hex(b: Uint8Array): string {
  let s = ''
  for (const x of b) s += x.toString(16).padStart(2, '0')
  return s
}

export function unhex(s: string): Uint8Array {
  if (s.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(s)) throw new E2eeError('bad hex')
  const out = new Uint8Array(s.length / 2)
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16)
  return out
}

export function b64(b: Uint8Array): string {
  let s = ''
  for (const x of b) s += String.fromCharCode(x)
  return btoa(s)
}

export function unb64(s: string): Uint8Array {
  // Accept both the standard and the URL-safe alphabet, padded or not.
  let t = s.trim().replace(/-/g, '+').replace(/_/g, '/')
  while (t.length % 4 !== 0) t += '='
  let bin: string
  try {
    bin = atob(t)
  } catch {
    throw new E2eeError('bad base64')
  }
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

/** Padded URL-safe base64, the format of the pairing codes (dart base64Url.encode). */
export function b64urlPadded(b: Uint8Array): string {
  return b64(b).replace(/\+/g, '-').replace(/\//g, '_')
}

export function constEq(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a[i]! ^ b[i]!
  return d === 0
}

export function u32(v: number): Uint8Array {
  const b = new Uint8Array(4)
  new DataView(b.buffer).setUint32(0, v >>> 0, false)
  return b
}

export function u64(v: number | bigint): Uint8Array {
  const b = new Uint8Array(8)
  new DataView(b.buffer).setBigUint64(0, BigInt(v), false)
  return b
}

export function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n)
  crypto.getRandomValues(b)
  return b
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

export function checkId(id: string): void {
  if (!UUID_RE.test(id)) throw new E2eeError('identifier must be a lower-case UUID')
}

export function newUuid(): string {
  const b = randomBytes(16)
  b[6] = (b[6]! & 0x0f) | 0x40
  b[8] = (b[8]! & 0x3f) | 0x80
  const h = hex(b)
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

const dom = (s: string): Uint8Array => utf8(s + '\x00')

export function hkdfSha256(ikm: Uint8Array, salt: Uint8Array | undefined, info: Uint8Array, len: number): Uint8Array {
  return hkdf(sha256, ikm, salt && salt.length ? salt : undefined, info, len)
}

// ---------------------------------------------------------------- identity

export function deriveIdentity(seed: Uint8Array): { edSeed: Uint8Array; xSecret: Uint8Array } {
  if (seed.length !== 32) throw new E2eeError('identity seed must be 32 bytes')
  return {
    edSeed: hkdfSha256(seed, undefined, utf8('OFE2EE1-IDENTITY-ED25519'), 32),
    xSecret: hkdfSha256(seed, undefined, utf8('OFE2EE1-IDENTITY-X25519'), 32),
  }
}

export const edPublic = (edSeed: Uint8Array): Uint8Array => ed25519.getPublicKey(edSeed)
export const xPublic = (xSecret: Uint8Array): Uint8Array => x25519.getPublicKey(xSecret)

export function edVerify(pub: Uint8Array, msg: Uint8Array, sig: Uint8Array): boolean {
  if (pub.length !== PUB_LEN || sig.length !== SIG_LEN) return false
  try {
    // Strict (RFC 8032) verification, like Go's crypto/ed25519 and Dart's cryptography.
    return ed25519.verify(sig, msg, pub, { zip215: false })
  } catch {
    return false
  }
}

export function fingerprint(edPub: Uint8Array, xPub: Uint8Array): Uint8Array {
  if (edPub.length !== PUB_LEN || xPub.length !== PUB_LEN) throw new E2eeError('key length')
  return sha256(cat(dom('OFE2EE1-FP'), edPub, xPub))
}

export function digitGroups(fp: Uint8Array): string {
  const d = sha512(cat(dom('OFE2EE1-DIGITS'), fp))
  const groups: string[] = []
  for (let i = 0; i < 12; i++) {
    let v = 0n
    for (let j = 0; j < 5; j++) v = (v << 8n) | BigInt(d[i * 5 + j]!)
    groups.push((v % 100000n).toString().padStart(5, '0'))
  }
  return groups.join(' ')
}

export function shortFingerprint(fp: Uint8Array): string {
  const h = hex(fp.slice(0, 8)).toUpperCase()
  return `${h.slice(0, 4)} ${h.slice(4, 8)} ${h.slice(8, 12)} ${h.slice(12, 16)}`
}

export function bindingMessage(userId: string, deviceId: string, edPub: Uint8Array, xPub: Uint8Array): Uint8Array {
  checkId(userId)
  checkId(deviceId)
  return cat(dom('OFE2EE1-BIND'), utf8(userId), utf8(deviceId), edPub, xPub)
}

export function logActionMessage(
  action: number,
  userId: string,
  actorDeviceId: string,
  opts: { circleId?: string; subjectId?: string; epoch?: number; ref?: Uint8Array } = {},
): Uint8Array {
  const circle = opts.circleId || ZERO_UUID
  const subject = opts.subjectId || ZERO_UUID
  for (const id of [userId, actorDeviceId, circle, subject]) checkId(id)
  const ref = opts.ref ?? new Uint8Array(32)
  if (ref.length !== 32 || action < ACT.register || action > ACT.approve) throw new E2eeError('bad log action')
  return cat(
    dom('OFE2EE1-LOGACT'),
    new Uint8Array([action]),
    utf8(userId),
    utf8(actorDeviceId),
    utf8(circle),
    utf8(subject),
    u32(opts.epoch ?? 0),
    ref,
  )
}

export function logEntryHash(prev: Uint8Array, seq: number, actionMsg: Uint8Array, sig: Uint8Array): Uint8Array {
  return sha256(cat(dom('OFE2EE1-LOG'), prev, u64(seq), actionMsg, sig))
}

export const GENESIS_HASH = new Uint8Array(32)

// ---------------------------------------------------------------- wrap

function epochBytes(epoch: number): Uint8Array {
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new E2eeError('epoch out of range')
  return u32(epoch)
}

export function wrapAad(circleId: string, epoch: number, recipientId: string, wrapperId: string): Uint8Array {
  for (const id of [circleId, recipientId, wrapperId]) checkId(id)
  return cat(dom('OFE2EE1-WRAP-AAD'), utf8(circleId), epochBytes(epoch), utf8(recipientId), utf8(wrapperId))
}

export function wrapSigMessage(circleId: string, epoch: number, recipientId: string, wrapperId: string, blob: Uint8Array): Uint8Array {
  if (blob.length !== WRAP_BLOB_LEN) throw new E2eeError('bad wrapped key')
  const aad = wrapAad(circleId, epoch, recipientId, wrapperId)
  return cat(dom('OFE2EE1-WRAP-SIG'), aad.slice(dom('OFE2EE1-WRAP-AAD').length), blob)
}

function wrapKey(shared: Uint8Array, epk: Uint8Array, recipientPub: Uint8Array): Uint8Array {
  return hkdfSha256(shared, cat(epk, recipientPub), dom('OFE2EE1-WRAP-KEY'), 32)
}

function nonZero(shared: Uint8Array): Uint8Array {
  let acc = 0
  for (const x of shared) acc |= x
  if (acc === 0) throw new E2eeError('weak key')
  return shared
}

/** Wrap with explicit randomness (test vectors and the test helpers only). */
export function wrapWithRandomness(circleKey: Uint8Array, recipientX: Uint8Array, aad: Uint8Array, esk: Uint8Array, nonce: Uint8Array): Uint8Array {
  const epk = x25519.getPublicKey(esk)
  const shared = nonZero(x25519.getSharedSecret(esk, recipientX))
  const k = wrapKey(shared, epk, recipientX)
  const ct = xchacha20poly1305(k, nonce, aad).encrypt(circleKey)
  return cat(new Uint8Array([WRAP_VERSION]), epk, nonce, ct)
}

/**
 * Opens a wrapped circle key. `ecdh` performs X25519(recipient secret, epk)
 * inside the key holder (a non-extractable WebCrypto key never leaves it).
 */
export async function unwrap(
  blob: Uint8Array,
  ecdh: (peerPub: Uint8Array) => Promise<Uint8Array>,
  recipientPub: Uint8Array,
  aad: Uint8Array,
): Promise<Uint8Array> {
  if (blob.length !== WRAP_BLOB_LEN || blob[0] !== WRAP_VERSION) throw new E2eeError('bad wrapped key')
  const epk = blob.slice(1, 33)
  const nonce = blob.slice(33, 57)
  const ct = blob.slice(57)
  const shared = nonZero(await ecdh(epk))
  const k = wrapKey(shared, epk, recipientPub)
  try {
    return xchacha20poly1305(k, nonce, aad).decrypt(ct)
  } catch {
    throw new E2eeError('decryption failed')
  }
}

export function keyCommitment(circleKey: Uint8Array, circleId: string, epoch: number): Uint8Array {
  if (circleKey.length !== KEY_LEN) throw new E2eeError('circle key must be 32 bytes')
  checkId(circleId)
  return hkdfSha256(circleKey, cat(utf8(circleId), epochBytes(epoch)), dom('OFE2EE1-KEY-COMMIT'), 32)
}

// ---------------------------------------------------------------- payloads

function msgKey(circleKey: Uint8Array, circleId: string, eb: Uint8Array, purpose: string): Uint8Array {
  return hkdfSha256(circleKey, cat(utf8(circleId), eb), cat(dom('OFE2EE1-MSG-KEY'), utf8(purpose)), 32)
}

function msgAad(circleId: string, eb: Uint8Array, senderId: string, purpose: string): Uint8Array {
  return cat(dom('OFE2EE1-MSG-AAD'), utf8(circleId), eb, utf8(senderId), new Uint8Array([purpose.length]), utf8(purpose))
}

export function sealWithNonce(
  circleKey: Uint8Array,
  circleId: string,
  epoch: number,
  senderId: string,
  purpose: string,
  plaintext: Uint8Array,
  nonce: Uint8Array,
): Uint8Array {
  if (purpose.length === 0 || purpose.length > 64) throw new E2eeError('bad purpose')
  checkId(circleId)
  checkId(senderId)
  const eb = epochBytes(epoch)
  const k = msgKey(circleKey, circleId, eb, purpose)
  const ct = xchacha20poly1305(k, nonce, msgAad(circleId, eb, senderId, purpose)).encrypt(plaintext)
  return cat(new Uint8Array([MSG_VERSION]), eb, nonce, ct)
}

export function open(circleKey: Uint8Array, circleId: string, senderId: string, purpose: string, payload: Uint8Array): Uint8Array {
  if (payload.length < 1 + 4 + NONCE_LEN + TAG_LEN) throw new E2eeError('ciphertext too short')
  if (payload[0] !== MSG_VERSION) throw new E2eeError('bad payload version')
  const eb = payload.slice(1, 5)
  const k = msgKey(circleKey, circleId, eb, purpose)
  try {
    return xchacha20poly1305(k, payload.slice(5, 5 + NONCE_LEN), msgAad(circleId, eb, senderId, purpose)).decrypt(
      payload.slice(5 + NONCE_LEN),
    )
  } catch {
    throw new E2eeError('decryption failed')
  }
}

export function payloadEpoch(payload: Uint8Array): number {
  if (payload.length < 5 || payload[0] !== MSG_VERSION) throw new E2eeError('bad payload')
  return new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getUint32(1, false)
}

export function padBucket(n: number): number {
  const need = n + 2
  for (const b of [256, 512, 1024, 4096]) if (need <= b) return b
  return Math.ceil(need / 4096) * 4096
}

export function pad(p: Uint8Array): Uint8Array {
  if (p.length > 0xffff) throw new E2eeError('payload too large')
  const out = new Uint8Array(padBucket(p.length))
  out[0] = p.length >> 8
  out[1] = p.length & 0xff
  out.set(p, 2)
  return out
}

export function unpad(p: Uint8Array): Uint8Array {
  if (p.length < 2) throw new E2eeError('short')
  const n = (p[0]! << 8) | p[1]!
  if (2 + n > p.length || padBucket(n) !== p.length) throw new E2eeError('bad padding')
  for (let i = 2 + n; i < p.length; i++) if (p[i] !== 0) throw new E2eeError('bad padding')
  return p.slice(2, 2 + n)
}

// ---------------------------------------------------------------- items

export function itemSignedMessage(
  circleId: string,
  epoch: number,
  deviceId: string,
  purpose: string,
  seq: number | bigint,
  tsMs: number | bigint,
  body: Uint8Array,
): Uint8Array {
  if (purpose.length === 0 || purpose.length > 64) throw new E2eeError('bad purpose')
  checkId(circleId)
  checkId(deviceId)
  return cat(
    dom('OFE2EE2-ITEM'),
    utf8(circleId),
    epochBytes(epoch),
    utf8(deviceId),
    new Uint8Array([purpose.length]),
    utf8(purpose),
    u64(seq),
    u64(tsMs),
    body,
  )
}

/** Test/helper only: a phone seals; the viewer never does. */
export function sealItem(
  circleKey: Uint8Array,
  circleId: string,
  epoch: number,
  deviceId: string,
  edSeed: Uint8Array,
  purpose: string,
  seq: number,
  tsMs: number,
  body: Uint8Array,
  nonce: Uint8Array,
): Uint8Array {
  const sig = ed25519.sign(itemSignedMessage(circleId, epoch, deviceId, purpose, seq, tsMs, body), edSeed)
  const env = cat(new Uint8Array([ITEM_VERSION]), u64(seq), u64(tsMs), sig, body)
  return sealWithNonce(circleKey, circleId, epoch, deviceId, purpose, pad(env), nonce)
}

export interface OpenedItem {
  seq: number
  tsMs: number
  body: Uint8Array
  epoch: number
}

/** Decrypts, checks the signed seq against the relayed one and verifies the sender's signature. */
export function openItem(
  circleKey: Uint8Array,
  circleId: string,
  deviceId: string,
  senderEdPub: Uint8Array,
  purpose: string,
  serverSeq: number,
  payload: Uint8Array,
): OpenedItem {
  const env = unpad(open(circleKey, circleId, deviceId, purpose, payload))
  if (env.length < 1 + 8 + 8 + SIG_LEN || env[0] !== ITEM_VERSION) throw new E2eeError('malformed item envelope')
  const dv = new DataView(env.buffer, env.byteOffset, env.byteLength)
  const seqBig = dv.getBigUint64(1, false)
  const tsBig = dv.getBigUint64(9, false)
  if (seqBig > BigInt(Number.MAX_SAFE_INTEGER) || tsBig > BigInt(Number.MAX_SAFE_INTEGER)) throw new E2eeError('item number out of range')
  const sig = env.slice(17, 17 + SIG_LEN)
  const body = env.slice(17 + SIG_LEN)
  const seq = Number(seqBig)
  if (seq !== serverSeq) throw new E2eeError('item seq does not match the server')
  const epoch = payloadEpoch(payload)
  const msg = itemSignedMessage(circleId, epoch, deviceId, purpose, seq, Number(tsBig), body)
  if (!edVerify(senderEdPub, msg, sig)) throw new E2eeError('item signature does not verify')
  return { seq, tsMs: Number(tsBig), body, epoch }
}
