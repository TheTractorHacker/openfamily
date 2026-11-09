// Account-bound web viewer ("sign in from any browser"): FIRST SLICE, NOT WIRED.
//
// Design: docs/design/WEB_VIEWER_ANYWHERE.md. Nothing in the app imports this module
// yet, and the server has no route that stores the blob, so the feature is OFF.
//
// What it does: the viewer's 32-byte identity seed (the same derivation as phones and
// as today's passphrase viewer) is sealed, together with the approving phone's key
// (the own-account anchor) and a name, under a random data key DEK. The DEK is wrapped
// by one or more "unlockers"; v1 has exactly one kind, a vault passphrase stretched with
// Argon2id. The result is an opaque JSON blob that a server may store: without the
// passphrase it is ciphertext. The pinned key-log head is sealed separately under the
// same DEK so it can be updated often without re-running Argon2id.
//
// Never: the passphrase, the DEK, the seed or a circle key leave this module unsealed;
// nothing here writes to localStorage/sessionStorage/IndexedDB or to the network.

import { argon2idAsync } from '@noble/hashes/argon2.js'
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js'
import { ed25519, x25519 } from '@noble/curves/ed25519.js'
import {
  E2eeError,
  b64,
  cat,
  checkId,
  constEq,
  deriveIdentity,
  edPublic,
  fromUtf8,
  hkdfSha256,
  randomBytes,
  u32,
  u64,
  unb64,
  utf8,
  xPublic,
} from './core.ts'
import type { KeyOps, Vault } from './keystore.ts'

export const AVAULT_VERSION = 1

/** Argon2id cost for the vault passphrase (same as today's passphrase viewer). */
export const AVAULT_ARGON_M_KIB = 64 * 1024
export const AVAULT_ARGON_T = 3
/** Floors enforced when sealing (tests may opt out) and caps enforced when opening (DoS guard). */
const MIN_M_KIB = 19 * 1024
const MIN_T = 2
const MAX_M_KIB = 1024 * 1024
const MAX_T = 10

export const MIN_PASSPHRASE_CHARS = 12

const dom = (s: string): Uint8Array => utf8(s + '\x00')
const D_PAYLOAD = 'OFE2EE-AVAULT1'
const D_KEK = 'OFE2EE-AVAULT1-KEK'
const D_PIN = 'OFE2EE-AVAULT1-PIN'

export interface PassphraseUnlocker {
  kind: 'passphrase'
  kdf: 'argon2id'
  m: number
  t: number
  p: 1
  salt: string // b64, 16 bytes
  nonce: string // b64, 24 bytes
  wrapped: string // b64, XChaCha20-Poly1305(KEK, nonce, AAD, DEK) = 48 bytes
}

/** The blob a server may store. Every field is authenticated (AAD) or ciphertext. */
export interface AccountVaultBlob {
  v: 1
  user_id: string
  device_id: string
  unlockers: PassphraseUnlocker[]
  nonce: string // b64, 24 bytes
  sealed: string // b64
}

export interface Anchor {
  deviceId: string
  edPub: string // b64
}

/** What the blob protects. */
export interface AccountVaultSecret {
  seed: Uint8Array
  /** The phone whose cross-signature registered this viewer (pinned at pairing). */
  approver: Anchor
  name: string
  createdAt: number
}

export interface PinRecord {
  v: 1
  seq: number // not secret (the server knows the log); bound in the AAD
  nonce: string
  sealed: string
}

export interface ArgonParams {
  m: number
  t: number
}

// ------------------------------------------------------------------ passphrase policy

/** Returns a reason the passphrase is too weak, or null. Deliberately simple (no dictionary shipped). */
export function passphraseProblem(pass: string, avoid: string[] = []): string | null {
  const p = pass.normalize('NFKC')
  if ([...p].length < MIN_PASSPHRASE_CHARS) return `use at least ${MIN_PASSPHRASE_CHARS} characters (a few unrelated words work well)`
  if (new Set([...p]).size < 5) return 'use more different characters'
  const low = p.toLowerCase()
  for (const a of avoid) {
    const x = a.trim().toLowerCase()
    if (x.length >= 4 && low.includes(x)) return 'do not reuse your email address or name'
  }
  return null
}

// ------------------------------------------------------------------ AADs

function kekAad(userId: string, deviceId: string, u: Pick<PassphraseUnlocker, 'kind' | 'kdf' | 'm' | 't' | 'p'>, salt: Uint8Array): Uint8Array {
  return cat(dom(D_KEK), utf8(userId), utf8(deviceId), dom(u.kind), dom(u.kdf), u32(u.m), u32(u.t), u32(u.p), salt)
}

function payloadAad(userId: string, deviceId: string): Uint8Array {
  return cat(dom(D_PAYLOAD), utf8(userId), utf8(deviceId), u32(AVAULT_VERSION))
}

function pinAad(userId: string, deviceId: string, seq: number): Uint8Array {
  return cat(dom(D_PIN), utf8(userId), utf8(deviceId), u64(seq))
}

async function kekFrom(pass: string, salt: Uint8Array, m: number, t: number): Promise<Uint8Array> {
  const root = await argon2idAsync(utf8(pass.normalize('NFKC')), salt, { t, m, p: 1, dkLen: 32 })
  const kek = hkdfSha256(root, undefined, utf8(D_KEK), 32)
  root.fill(0)
  return kek
}

async function makeUnlocker(userId: string, deviceId: string, dek: Uint8Array, pass: string, argon: ArgonParams): Promise<PassphraseUnlocker> {
  const salt = randomBytes(16)
  const nonce = randomBytes(24)
  const shape = { kind: 'passphrase' as const, kdf: 'argon2id' as const, m: argon.m, t: argon.t, p: 1 as const }
  const kek = await kekFrom(pass, salt, argon.m, argon.t)
  const wrapped = xchacha20poly1305(kek, nonce, kekAad(userId, deviceId, shape, salt)).encrypt(dek)
  kek.fill(0)
  return { ...shape, salt: b64(salt), nonce: b64(nonce), wrapped: b64(wrapped) }
}

function checkArgon(a: ArgonParams, allowWeak: boolean) {
  if (!Number.isInteger(a.m) || !Number.isInteger(a.t) || a.m > MAX_M_KIB || a.t > MAX_T || a.m < 8 || a.t < 1) {
    throw new E2eeError('unsupported key-stretching parameters')
  }
  if (!allowWeak && (a.m < MIN_M_KIB || a.t < MIN_T)) throw new E2eeError('key-stretching parameters are too weak')
}

// ------------------------------------------------------------------ seal / open

export interface SealOpts {
  userId: string
  deviceId: string
  secret: AccountVaultSecret
  passphrase: string
  /** Extra strings the passphrase must not contain (email, display name). */
  avoid?: string[]
  argon?: ArgonParams
  /** Tests only: allow tiny Argon2 parameters and skip the passphrase policy. */
  testing?: boolean
}

/** Seals a viewer identity into a blob. Returns the DEK too (kept in memory to seal pin records). */
export async function sealAccountVault(o: SealOpts): Promise<{ blob: AccountVaultBlob; dek: Uint8Array }> {
  checkId(o.userId)
  checkId(o.deviceId)
  checkId(o.secret.approver.deviceId)
  if (o.secret.seed.length !== 32) throw new E2eeError('identity seed must be 32 bytes')
  if (!o.testing) {
    const why = passphraseProblem(o.passphrase, o.avoid)
    if (why) throw new E2eeError(why)
  }
  const argon = o.argon ?? { m: AVAULT_ARGON_M_KIB, t: AVAULT_ARGON_T }
  checkArgon(argon, !!o.testing)
  const dek = randomBytes(32)
  const nonce = randomBytes(24)
  const body = utf8(
    JSON.stringify({
      seed: b64(o.secret.seed),
      approver: { deviceId: o.secret.approver.deviceId, edPub: o.secret.approver.edPub },
      name: o.secret.name.slice(0, 40),
      createdAt: o.secret.createdAt,
    }),
  )
  const sealed = xchacha20poly1305(dek, nonce, payloadAad(o.userId, o.deviceId)).encrypt(body)
  body.fill(0)
  const unlocker = await makeUnlocker(o.userId, o.deviceId, dek, o.passphrase, argon)
  return {
    blob: { v: 1, user_id: o.userId, device_id: o.deviceId, unlockers: [unlocker], nonce: b64(nonce), sealed: b64(sealed) },
    dek,
  }
}

function parseBlob(raw: unknown): AccountVaultBlob {
  const b = (typeof raw === 'string' ? JSON.parse(raw) : raw) as AccountVaultBlob
  if (!b || b.v !== 1 || typeof b.user_id !== 'string' || typeof b.device_id !== 'string' || !Array.isArray(b.unlockers)) {
    throw new E2eeError('not a viewer vault (unknown format)')
  }
  checkId(b.user_id)
  checkId(b.device_id)
  return b
}

export interface OpenOpts {
  passphrase: string
  /** The signed-in account. A blob for another account is refused. */
  userId: string
}

/** Opens a blob. Wrong passphrase, another account, or any tampering throws. */
export async function openAccountVault(raw: unknown, o: OpenOpts): Promise<{ secret: AccountVaultSecret; dek: Uint8Array; deviceId: string }> {
  const b = parseBlob(raw)
  if (b.user_id !== o.userId) throw new E2eeError('this viewer vault belongs to another account')
  let dek: Uint8Array | null = null
  for (const u of b.unlockers) {
    if (u.kind !== 'passphrase' || u.kdf !== 'argon2id' || u.p !== 1) continue
    checkArgon({ m: u.m, t: u.t }, true)
    const salt = unb64(u.salt)
    const kek = await kekFrom(o.passphrase, salt, u.m, u.t)
    try {
      dek = xchacha20poly1305(kek, unb64(u.nonce), kekAad(b.user_id, b.device_id, u, salt)).decrypt(unb64(u.wrapped))
    } catch {
      dek = null
    } finally {
      kek.fill(0)
    }
    if (dek) break
  }
  if (!dek || dek.length !== 32) throw new E2eeError('wrong vault passphrase')
  let body: Uint8Array
  try {
    body = xchacha20poly1305(dek, unb64(b.nonce), payloadAad(b.user_id, b.device_id)).decrypt(unb64(b.sealed))
  } catch {
    throw new E2eeError('the viewer vault was altered')
  }
  const j = JSON.parse(fromUtf8(body)) as { seed: string; approver: Anchor; name: string; createdAt: number }
  body.fill(0)
  const seed = unb64(j.seed)
  if (seed.length !== 32 || !j.approver || typeof j.approver.deviceId !== 'string') throw new E2eeError('the viewer vault is malformed')
  checkId(j.approver.deviceId)
  return { secret: { seed, approver: { deviceId: j.approver.deviceId, edPub: j.approver.edPub }, name: String(j.name ?? ''), createdAt: Number(j.createdAt) || 0 }, dek, deviceId: b.device_id }
}

/** Re-wraps the DEK under a new passphrase (the seed and the key on the server do not change). */
export async function changeVaultPassphrase(
  raw: unknown,
  dek: Uint8Array,
  newPassphrase: string,
  o: { avoid?: string[]; argon?: ArgonParams; testing?: boolean } = {},
): Promise<AccountVaultBlob> {
  const b = parseBlob(raw)
  if (!o.testing) {
    const why = passphraseProblem(newPassphrase, o.avoid)
    if (why) throw new E2eeError(why)
  }
  // The DEK must really open this blob, so a wrong DEK can never produce an unopenable vault.
  try {
    xchacha20poly1305(dek, unb64(b.nonce), payloadAad(b.user_id, b.device_id)).decrypt(unb64(b.sealed))
  } catch {
    throw new E2eeError('that key does not open this viewer vault')
  }
  const argon = o.argon ?? { m: AVAULT_ARGON_M_KIB, t: AVAULT_ARGON_T }
  checkArgon(argon, !!o.testing)
  const u = await makeUnlocker(b.user_id, b.device_id, dek, newPassphrase, argon)
  return { ...b, unlockers: [u] }
}

// ------------------------------------------------------------------ key-log pin

export interface LogHead {
  seq: number
  hash: string
}

export function sealPin(dek: Uint8Array, userId: string, deviceId: string, head: LogHead): PinRecord {
  if (!Number.isSafeInteger(head.seq) || head.seq < 0) throw new E2eeError('bad log head')
  const nonce = randomBytes(24)
  const sealed = xchacha20poly1305(dek, nonce, pinAad(userId, deviceId, head.seq)).encrypt(utf8(JSON.stringify(head)))
  return { v: 1, seq: head.seq, nonce: b64(nonce), sealed: b64(sealed) }
}

/** Opens a pin record; returns null if it is missing, altered, or for another account/device. */
export function openPin(dek: Uint8Array, userId: string, deviceId: string, rec: PinRecord | null | undefined): LogHead | null {
  if (!rec || rec.v !== 1 || !Number.isSafeInteger(rec.seq)) return null
  try {
    const h = JSON.parse(fromUtf8(xchacha20poly1305(dek, unb64(rec.nonce), pinAad(userId, deviceId, rec.seq)).decrypt(unb64(rec.sealed)))) as LogHead
    if (h.seq !== rec.seq || typeof h.hash !== 'string') return null
    return { seq: h.seq, hash: h.hash }
  } catch {
    return null
  }
}

/**
 * The pin to verify the log against: the higher of what this browser remembers and what the
 * server returned. The server can only hand back an OLDER genuine pin (it cannot forge one),
 * so taking the maximum never lets it move a browser backwards.
 */
export function newerPin(local: LogHead | null, remote: LogHead | null): LogHead | null {
  if (!local) return remote
  if (!remote) return local
  return remote.seq > local.seq ? remote : local
}

// ------------------------------------------------------------------ identity in memory

export interface RegisteredKey {
  device_id: string
  kind?: string
  ed25519_pub: string
  x25519_pub: string
  revoked_at?: string | null
}

/**
 * Turns an opened vault into in-memory key operations, after checking that the seed really is
 * the key the server lists for this account (active `web` key with the same id and public keys).
 */
export function accountIdentity(secret: AccountVaultSecret, deviceId: string, record: RegisteredKey): { ops: KeyOps; vault: Vault } {
  const { edSeed, xSecret } = deriveIdentity(secret.seed)
  const edPub = edPublic(edSeed)
  const xPub = xPublic(xSecret)
  if (record.device_id !== deviceId) throw new E2eeError('the server lists a different viewer key')
  if (record.revoked_at) throw new E2eeError('this viewer key was revoked; set up web access again from a phone')
  if (record.kind !== undefined && record.kind !== 'web') throw new E2eeError('this key is not a web viewer key')
  if (!constEq(unb64(record.ed25519_pub), edPub) || !constEq(unb64(record.x25519_pub), xPub)) {
    throw new E2eeError('the viewer vault does not match the registered key')
  }
  const ops: KeyOps = {
    mode: 'session',
    edPub,
    xPub,
    async sign(msg) {
      return ed25519.sign(msg, edSeed)
    },
    async ecdh(peer) {
      const s = x25519.getSharedSecret(xSecret, peer)
      if (s.every((v) => v === 0)) throw new E2eeError('weak shared secret')
      return s
    },
  }
  // Circle keys are re-opened from the server's wraps each session and kept in memory only.
  const mem = new Map<string, Uint8Array>()
  const vault: Vault = {
    mode: 'session',
    async putCircleKey(c, e, k) {
      mem.set(`${c}:${e}`, k.slice())
    },
    async getCircleKey(c, e) {
      return mem.get(`${c}:${e}`)?.slice() ?? null
    },
    async heldEpochs(c) {
      return [...mem.keys()]
        .filter((k) => k.startsWith(`${c}:`))
        .map((k) => Number(k.slice(c.length + 1)))
        .filter((n) => Number.isInteger(n) && n > 0)
        .sort((a, b) => a - b)
    },
  }
  return { ops, vault }
}
