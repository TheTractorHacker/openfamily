// Web access from any browser: the HTTP side of the account-bound viewer vault
// (docs/design/WEB_VIEWER_ANYWHERE.md). The crypto is in accountVault.ts.
//
// Flow, in plain words:
//  set up   make a key in memory -> phone approves it (the usual pairing) -> the browser
//           seals the key under the vault passphrase (+ the server's pepper, released
//           after password + 2FA) and stores the sealed blob on the server.
//  unlock   password + 2FA -> the server releases the blob and the pepper -> the
//           browser opens it with the vault passphrase, in memory only.
// The vault passphrase never leaves this file except into Argon2id.

import { E2eeError, b64, deriveIdentity, edPublic, randomBytes, unb64, xPublic } from './core.ts'
import {
  type AccountVaultBlob,
  type Anchor,
  type LogHead,
  type PinRecord,
  type RegisteredKey,
  accountIdentity,
  changeVaultPassphrase,
  openAccountVault,
  openPin,
  passphraseProblem,
  sealAccountVault,
  sealPin,
} from './accountVault.ts'
import type { IdentityMeta, KeyOps, Vault } from './keystore.ts'
import type { Http } from './viewer.ts'

export interface VaultHttp extends Http {
  put<T>(path: string, body: unknown): Promise<T>
}

export interface VaultStatus {
  available: boolean
  /** Why not available: off_by_operator | off_in_settings | pepper_unavailable | admins_only. */
  reason: string
  exists: boolean
  device_id?: string
  created_at?: string
  updated_at?: string
  last_opened_at?: string | null
  pepper_changed?: boolean
  key_active?: boolean
}

interface UnlockReply {
  pepper: string
  ticket: string
  blob: AccountVaultBlob | null
  pin: PinRecord | null
  device_id: string | null
}

export interface StepUp {
  password: string
  totpCode?: string
}

const BROWSER_ID_KEY = 'orbitly-browser-id'

/** A random, non-secret id for this browser (only its hash is stored, for the "new browser" notice). */
export function browserId(store: Pick<Storage, 'getItem' | 'setItem'> | null = typeof localStorage === 'undefined' ? null : localStorage): string {
  try {
    const have = store?.getItem(BROWSER_ID_KEY)
    if (have && /^[A-Za-z0-9_-]{22,64}$/.test(have)) return have
    const id = b64(randomBytes(24)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
    store?.setItem(BROWSER_ID_KEY, id)
    return id
  } catch {
    return ''
  }
}

export function vaultStatus(http: VaultHttp): Promise<VaultStatus> {
  return http.get<VaultStatus>('/e2ee/viewer-vault')
}

async function stepUp(http: VaultHttp, s: StepUp, browser: string): Promise<UnlockReply> {
  return http.post<UnlockReply>('/e2ee/viewer-vault/unlock', {
    password: s.password,
    totp_code: s.totpCode?.trim() || undefined,
    browser_id: browser || undefined,
  })
}

/** A fresh viewer key held in memory until it is approved and sealed. */
export interface PendingAccountKey {
  meta: IdentityMeta
  ops: KeyOps
  vault: Vault
  seed: Uint8Array
}

export function newAccountKey(userId: string, deviceId: string, name: string): PendingAccountKey {
  const seed = randomBytes(32)
  const { edSeed, xSecret } = deriveIdentity(seed)
  const edPub = edPublic(edSeed)
  const xPub = xPublic(xSecret)
  const meta: IdentityMeta = {
    mode: 'account',
    userId,
    deviceId,
    name: name.slice(0, 40),
    edPub: b64(edPub),
    xPub: b64(xPub),
    registered: false,
    createdAt: Date.now(),
  }
  // Same in-memory key operations as an unlocked vault; the seed matches by construction.
  const record: RegisteredKey = { device_id: deviceId, kind: 'web', ed25519_pub: b64(edPub), x25519_pub: b64(xPub) }
  const { ops, vault } = accountIdentity({ seed, approver: { deviceId, edPub: b64(edPub) }, name, createdAt: meta.createdAt }, deviceId, record)
  return { meta, ops, vault, seed }
}

export interface Opened {
  meta: IdentityMeta
  ops: KeyOps
  vault: Vault
  dek: Uint8Array
  remotePin: LogHead | null
}

/** Seals an approved key and stores it. Returns the DEK (kept in memory for pin updates). */
export async function saveAccountKey(
  http: VaultHttp,
  key: PendingAccountKey,
  approver: Anchor,
  passphrase: string,
  s: StepUp,
  opts: { avoid?: string[]; browser?: string; testArgon?: { m: number; t: number } } = {},
): Promise<Uint8Array> {
  if (!key.meta.registered) throw new E2eeError('approve the key on your phone first')
  // Owner decision D2: the vault passphrase must not be the account password.
  if (passphrase === s.password) throw new E2eeError('choose a vault passphrase that is different from your account password')
  const why = passphraseProblem(passphrase, opts.avoid)
  if (why) throw new E2eeError(why)
  const r = await stepUp(http, s, opts.browser ?? browserId())
  const { blob, dek } = await sealAccountVault({
    userId: key.meta.userId,
    deviceId: key.meta.deviceId,
    secret: { seed: key.seed, approver, name: key.meta.name, createdAt: key.meta.createdAt },
    passphrase,
    avoid: opts.avoid,
    pepper: unb64(r.pepper),
    argon: opts.testArgon,
    testing: !!opts.testArgon,
  })
  await http.put('/e2ee/viewer-vault', { ticket: r.ticket, blob })
  return dek
}

/** Unlocks the stored key in memory. Wrong passphrase, another account, or a mismatching key all throw. */
export async function unlockAccountKey(http: VaultHttp, userId: string, passphrase: string, s: StepUp, browser = browserId()): Promise<Opened> {
  const r = await stepUp(http, s, browser)
  if (!r.blob) throw new E2eeError('web access is not set up for this account yet')
  const pepper = unb64(r.pepper)
  const opened = await openAccountVault(r.blob, { passphrase, userId, pepper })
  const me = await http.get<{ devices: (RegisteredKey & { revoked_at?: string | null })[] }>('/e2ee/me')
  const record = (me.devices ?? []).find((d) => d.device_id === opened.deviceId)
  if (!record) throw new E2eeError('the server no longer lists this web access key; set it up again')
  const { ops, vault } = accountIdentity(opened.secret, opened.deviceId, record)
  opened.secret.seed.fill(0)
  const meta: IdentityMeta = {
    mode: 'account',
    userId,
    deviceId: opened.deviceId,
    name: opened.secret.name,
    edPub: b64(ops.edPub),
    xPub: b64(ops.xPub),
    registered: true,
    createdAt: opened.secret.createdAt,
    approver: opened.secret.approver,
  }
  return { meta, ops, vault, dek: opened.dek, remotePin: openPin(opened.dek, userId, opened.deviceId, r.pin) }
}

/** Re-seals under a new passphrase (needs password + 2FA again). The key itself does not change. */
export async function changeAccountPassphrase(
  http: VaultHttp,
  userId: string,
  dek: Uint8Array,
  newPassphrase: string,
  s: StepUp,
  opts: { avoid?: string[]; testArgon?: { m: number; t: number } } = {},
): Promise<void> {
  if (newPassphrase === s.password) throw new E2eeError('choose a vault passphrase that is different from your account password')
  const why = passphraseProblem(newPassphrase, opts.avoid)
  if (why) throw new E2eeError(why)
  const r = await stepUp(http, s, browserId())
  if (!r.blob || r.blob.user_id !== userId) throw new E2eeError('web access is not set up for this account')
  const next = await changeVaultPassphrase(r.blob, dek, newPassphrase, {
    avoid: opts.avoid,
    pepper: unb64(r.pepper),
    argon: opts.testArgon,
    testing: !!opts.testArgon,
  })
  await http.put('/e2ee/viewer-vault', { ticket: r.ticket, blob: next })
}

/** Uploads the sealed log head (best effort; the server keeps only a newer one). */
export async function pushPin(http: VaultHttp, dek: Uint8Array, userId: string, deviceId: string, head: LogHead): Promise<void> {
  if (head.seq < 1) return
  await http.put('/e2ee/viewer-vault/pin', { pin: sealPin(dek, userId, deviceId, head) })
}

export function deleteVault(http: VaultHttp): Promise<{ deleted: boolean }> {
  return http.del<{ deleted: boolean }>('/e2ee/viewer-vault')
}
