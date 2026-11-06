// Client-side verification policy: registrations, epoch records, wrapped keys
// and the key transparency log. A port of backend/internal/e2ee/verify.go and
// the phone's e2ee_trust.dart. The server is the adversary: nothing is trusted
// because the server said so.

import {
  ACT,
  E2eeError,
  GENESIS_HASH,
  WRAP_BLOB_LEN,
  bindingMessage,
  constEq,
  edVerify,
  fingerprint,
  keyCommitment,
  logActionMessage,
  logEntryHash,
  unb64,
  unhex,
  unwrap,
  wrapAad,
  wrapSigMessage,
} from './core.ts'


export interface DeviceRecord {
  device_id: string
  user_id: string
  kind: string
  ed25519_pub: string
  x25519_pub: string
  fingerprint: string
  signature: string
  registered_by_device_id: string
  registered_by_ed25519_pub: string
  registration_action: number
  registration_signature: string
  initial?: boolean
  label?: string
  revoked_at?: string | null
  approved?: boolean
  created_at?: string
  digits?: string
  short?: string
}

function tryDecode<T>(f: () => T): T | null {
  try {
    return f()
  } catch {
    return null
  }
}

/** Vouching signature chain of one key (and the self-signed binding), like Go VerifyRegistration. */
export function verifyRegistration(d: DeviceRecord): boolean {
  const ed = tryDecode(() => unb64(d.ed25519_pub))
  const x = tryDecode(() => unb64(d.x25519_pub))
  const bind = tryDecode(() => unb64(d.signature))
  const byPub = tryDecode(() => unb64(d.registered_by_ed25519_pub))
  const rsig = tryDecode(() => unb64(d.registration_signature))
  const ref = tryDecode(() => unhex(d.fingerprint))
  if (!ed || !x || !bind || !byPub || !rsig || !ref) return false
  if (d.registration_action < ACT.register || d.registration_action > ACT.approve) return false
  try {
    const msg = logActionMessage(d.registration_action, d.user_id, d.registered_by_device_id, {
      subjectId: d.device_id,
      ref,
    })
    const isRoot = d.registered_by_device_id === d.device_id
    if (isRoot && !constEq(byPub, ed)) return false
    if (!constEq(fingerprint(ed, x), ref)) return false
    if (!edVerify(ed, bindingMessage(d.user_id, d.device_id, ed, x), bind)) return false
    return edVerify(byPub, msg, rsig)
  } catch {
    return false
  }
}

export interface EpochRecord {
  epoch: number
  action: number
  publisher_user_id: string
  publisher_device_id: string
  publisher_ed25519_pub: string
  key_commitment: string
  signature: string
}

export function verifyEpochRecord(circleId: string, r: EpochRecord): boolean {
  if ((r.action !== ACT.enable && r.action !== ACT.epoch) || r.epoch < 1) return false
  try {
    const pub = unb64(r.publisher_ed25519_pub)
    const commit = unb64(r.key_commitment)
    const sig = unb64(r.signature)
    const msg = logActionMessage(r.action, r.publisher_user_id, r.publisher_device_id, {
      circleId,
      epoch: r.epoch,
      ref: commit,
    })
    return edVerify(pub, msg, sig)
  } catch {
    return false
  }
}

export interface WrapRecord {
  epoch: number
  recipient_device_id: string
  wrapper_device_id: string
  wrapper_ed25519_pub: string
  wrapped_key: string
  signature: string
}

/**
 * Verifies and unwraps one circle key like the phone's syncCircleKeys: recipient
 * is this device, wrapper signature, signed epoch record, AEAD with the AAD that
 * binds circle/epoch/recipient/wrapper, and the key commitment. Fails closed.
 */
export async function openWrap(
  circleId: string,
  deviceId: string,
  ecdh: (peer: Uint8Array) => Promise<Uint8Array>,
  xPub: Uint8Array,
  w: WrapRecord,
  rec: EpochRecord | undefined,
): Promise<Uint8Array> {
  const reject = (why: string): never => {
    throw new E2eeError(`wrap rejected: ${why}`)
  }
  if (w.recipient_device_id !== deviceId || w.epoch < 1 || !rec || rec.epoch !== w.epoch) reject('not addressed to this device or no epoch record')
  const blob = tryDecode(() => unb64(w.wrapped_key))
  const wsig = tryDecode(() => unb64(w.signature))
  const wpub = tryDecode(() => unb64(w.wrapper_ed25519_pub))
  if (!blob || !wsig || !wpub || blob.length !== WRAP_BLOB_LEN) return reject('malformed')
  if (!edVerify(wpub, wrapSigMessage(circleId, w.epoch, deviceId, w.wrapper_device_id, blob), wsig)) reject('wrapper signature')
  if (!verifyEpochRecord(circleId, rec!)) reject('epoch record signature')
  let key: Uint8Array
  try {
    key = await unwrap(blob, ecdh, xPub, wrapAad(circleId, w.epoch, deviceId, w.wrapper_device_id))
  } catch {
    return reject('cannot unwrap')
  }
  const want = unb64(rec!.key_commitment)
  if (!constEq(keyCommitment(key, circleId, w.epoch), want)) reject('key commitment mismatch')
  return key
}

// ------------------------------------------------------------------ the log

export interface LogEntry {
  seq: number
  prev_hash: string
  entry_hash: string
  redacted: boolean
  action?: number
  user_id?: string
  actor_device_id?: string
  actor_ed25519_pub?: string
  circle_id?: string | null
  subject_id?: string | null
  epoch?: number
  ref?: string
  signature?: string
}

export interface LogHead {
  seq: number
  hash: string // hex; '' or 64 zeros at seq 0
}

export type LogProblem = 'rollback' | 'fork' | 'broken-chain' | 'bad-signature' | 'bad-hash' | 'gap' | 'malformed'

export interface LogCheck {
  ok: boolean
  problem?: LogProblem
  detail?: string
  newHead?: LogHead
  events: LogEntry[]
}

const bad = (problem: LogProblem, detail: string): LogCheck => ({ ok: false, problem, detail, events: [] })

function hash32(s: string): Uint8Array | null {
  const b = tryDecode(() => unhex(s))
  return b && b.length === 32 ? b : null
}

const headHash = (h: LogHead): Uint8Array => (h.hash ? (hash32(h.hash) ?? new Uint8Array(32)) : new Uint8Array(32))

export function verifyLogSlice(pinned: LogHead | null, entries: LogEntry[], head: LogHead): LogCheck {
  if (pinned && head.seq < pinned.seq) {
    return bad('rollback', `the server log is shorter (${head.seq}) than the one pinned (${pinned.seq})`)
  }
  const pinnedHash = pinned ? headHash(pinned) : null
  if (entries.length === 0) {
    if (!pinned && head.seq === 0) return { ok: true, newHead: head, events: [] }
    if (pinned && head.seq === pinned.seq && constEq(headHash(head), pinnedHash!)) return { ok: true, newHead: head, events: [] }
    return bad('gap', 'the server returned no entries but a different head')
  }
  let prev: Uint8Array | null = null
  let lastSeq = 0
  let first = true
  const events: LogEntry[] = []
  for (const e of entries) {
    const ePrev = hash32(e.prev_hash)
    const eHash = hash32(e.entry_hash)
    if (!ePrev || !eHash) return bad('malformed', `entry ${e.seq} is malformed`)
    if (!first && e.seq !== lastSeq + 1) return bad('gap', `entry ${lastSeq + 1} is missing`)
    if (first) {
      if (!pinned && e.seq !== 1) return bad('gap', 'the log does not start at entry 1')
      if (pinned && e.seq > pinned.seq) return bad('gap', 'the pinned entry was not returned')
      if (e.seq === 1 && !constEq(ePrev, GENESIS_HASH)) return bad('broken-chain', 'entry 1 does not start from the genesis hash')
    } else if (!constEq(ePrev, prev!)) {
      return bad('broken-chain', `entry ${e.seq} does not extend entry ${e.seq - 1}`)
    }
    if (!e.redacted) {
      try {
        if (e.action === undefined || !e.user_id || !e.actor_device_id || !e.actor_ed25519_pub || !e.signature || e.ref === undefined) {
          return bad('malformed', `entry ${e.seq} is malformed`)
        }
        const msg = logActionMessage(e.action, e.user_id, e.actor_device_id, {
          circleId: e.circle_id || undefined,
          subjectId: e.subject_id || undefined,
          epoch: e.epoch ?? 0,
          ref: unhex(e.ref),
        })
        const sig = unb64(e.signature)
        if (!edVerify(unb64(e.actor_ed25519_pub), msg, sig)) return bad('bad-signature', `entry ${e.seq} has an invalid signature`)
        if (!constEq(logEntryHash(ePrev, e.seq, msg, sig), eHash)) return bad('bad-hash', `entry ${e.seq} does not match its hash`)
      } catch {
        return bad('malformed', `entry ${e.seq} is malformed`)
      }
    }
    if (pinned && e.seq === pinned.seq && !constEq(eHash, pinnedHash!)) {
      return bad('fork', `entry ${pinned.seq} is not the one pinned: the history was rewritten or another log is shown`)
    }
    if ((!pinned || e.seq > pinned.seq) && !e.redacted) events.push(e)
    prev = eHash
    lastSeq = e.seq
    first = false
  }
  if (pinned && lastSeq < pinned.seq) return bad('gap', 'the pinned entry was not returned')
  if (lastSeq !== head.seq || !constEq(prev!, headHash(head))) return bad('broken-chain', 'the reported head is not the last entry')
  return { ok: true, newHead: head, events }
}

export type LogFetcher = (after: number) => Promise<{ entries: LogEntry[]; head: LogHead }>

/** Walks the whole log page by page from the pinned head, verifying each page. */
export async function syncLog(pinned: LogHead | null, fetchPage: LogFetcher): Promise<LogCheck> {
  let cur = pinned
  const events: LogEntry[] = []
  for (let page = 0; page < 100000; page++) {
    const after = cur && cur.seq > 0 ? cur.seq - 1 : 0
    const { entries, head } = await fetchPage(after)
    if (cur && head.seq < cur.seq) return bad('rollback', `the server log is shorter (${head.seq}) than the one pinned (${cur.seq})`)
    let tip = head
    const last = entries[entries.length - 1]
    if (last && last.seq !== head.seq) tip = { seq: last.seq, hash: last.entry_hash }
    const c = verifyLogSlice(cur, entries, tip)
    if (!c.ok) return c
    events.push(...c.events)
    const progressed = !cur || c.newHead!.seq > cur.seq
    cur = c.newHead!
    if (cur.seq === head.seq) {
      if (!constEq(headHash(cur), headHash(head))) return bad('broken-chain', 'the reported head is not the last entry')
      return { ok: true, newHead: cur, events }
    }
    if (!progressed) return bad('gap', 'the server did not advance the log')
  }
  return bad('gap', 'the log is too long to verify')
}

// ------------------------------------------------- authorization against the log
//
// The circle state is served by the adversary. A key is accepted only if the state
// lists it with the same public key, its registration signatures verify, the
// VERIFIED transparency log contains that registration (and its voucher chain),
// it is approved and neither revoked in the state nor in the log. Everything here
// fails closed. Mirrors backend/internal/e2ee/verify.go (AuthorizeWrap/Sender).

export interface CircleMember {
  user_id: string
  name: string
  role: string
  devices: DeviceRecord[]
}

export class LogIndex {
  hashes = new Map<number, string>()
  regs = new Map<string, LogEntry>()
  epochs = new Map<string, LogEntry>()
  /** device -> first logged revoke OR rotate-away (its key was replaced) */
  revoked = new Map<string, number>()
  /** user -> ascending sequence numbers of reset entries (each retires all earlier keys of that user) */
  resets = new Map<string, number[]>()
  /** The one Ed25519 key each acting device id has used in the log. */
  actorKey = new Map<string, string>()
  /** Set when one device id shows two different keys, or is registered twice (the log is then not trusted). */
  conflict = ''

  add(e: LogEntry): void {
    this.hashes.set(e.seq, e.entry_hash)
    if (e.redacted || e.action === undefined) return
    if (e.actor_device_id && e.actor_ed25519_pub) {
      const k = this.actorKey.get(e.actor_device_id)
      if (k === undefined) this.actorKey.set(e.actor_device_id, e.actor_ed25519_pub)
      else if (k !== e.actor_ed25519_pub && !this.conflict) this.conflict = `entry ${e.seq}: device ${e.actor_device_id} signs with a different key than before`
    }
    if (e.action === ACT.enable || e.action === ACT.epoch) {
      if (e.circle_id && e.epoch !== undefined) this.epochs.set(`${e.circle_id}|${e.epoch}`, e)
    } else if (e.action === ACT.register || e.action === ACT.rotate || e.action === ACT.recovery || e.action === ACT.reset) {
      // A rotation retires the OLD key (the actor); a reset retires every earlier key of the user.
      // The server writes no separate revoke entry for either.
      if (e.action === ACT.rotate && e.actor_device_id && !this.revoked.has(e.actor_device_id)) this.revoked.set(e.actor_device_id, e.seq)
      if (e.action === ACT.reset && e.user_id) this.resets.set(e.user_id, [...(this.resets.get(e.user_id) ?? []), e.seq])
      if (e.subject_id) {
        if (this.regs.has(e.subject_id)) {
          if (!this.conflict) this.conflict = `entry ${e.seq}: device ${e.subject_id} is registered twice`
        } else this.regs.set(e.subject_id, e)
      }
    } else if (e.action === ACT.revoke) {
      if (e.subject_id && !this.revoked.has(e.subject_id)) this.revoked.set(e.subject_id, e.seq)
    }
  }

  /** Sequence number at which the log retires a device (revoke, rotated away, or a later reset of its user). */
  revokeSeq(deviceId: string): number | undefined {
    let best = this.revoked.get(deviceId)
    const reg = this.regs.get(deviceId)
    if (reg?.user_id) {
      for (const rs of this.resets.get(reg.user_id) ?? []) {
        if (rs > reg.seq) {
          if (best === undefined || rs < best) best = rs
          break
        }
      }
    }
    return best
  }

  isRevoked(deviceId: string): boolean {
    return this.revokeSeq(deviceId) !== undefined
  }

  registrationLogged(d: DeviceRecord): boolean {
    const e = this.regs.get(d.device_id)
    return (
      !!e &&
      e.action === d.registration_action &&
      e.user_id === d.user_id &&
      e.actor_device_id === d.registered_by_device_id &&
      e.ref === d.fingerprint &&
      e.signature === d.registration_signature &&
      e.actor_ed25519_pub === d.registered_by_ed25519_pub
    )
  }

  /**
   * Follows the voucher chain to a self-registered root and returns the devices on it (leaf first).
   * Fail-closed rules: every hop is in the log field for field; EVERY voucher is listed in the state
   * with a registration that verifies, the same user, and its own registration in the log field for
   * field (so the key we trust is bound to the fingerprint the log recorded, not merely listed); the
   * voucher key used equals the key that device id always signed with in the log; a voucher retired
   * in the log (revoke, rotation, reset) BEFORE the vouched registration cannot mint devices.
   */
  walkChain(d: DeviceRecord, members: CircleMember[]): { id: string; pub: string }[] | null {
    const own = this.actorKey.get(d.device_id)
    if (own !== undefined && own !== d.ed25519_pub) return null
    let cur = d
    const nodes = [{ id: d.device_id, pub: d.ed25519_pub }]
    for (let depth = 0; depth < 16; depth++) {
      if (!this.registrationLogged(cur)) return null
      const regSeq = this.regs.get(cur.device_id)!.seq
      const v = cur.registered_by_device_id
      const k = this.actorKey.get(v)
      if (k === undefined || k !== cur.registered_by_ed25519_pub) return null
      if (v === cur.device_id) {
        if (cur.ed25519_pub && cur.ed25519_pub !== k) return null
        return nodes // self-registered root, anchored by its own key
      }
      const listed = findDevice(members, v)
      if (
        !listed ||
        listed.dev.ed25519_pub !== k ||
        listed.dev.user_id !== d.user_id ||
        !verifyRegistration(listed.dev) ||
        !this.registrationLogged(listed.dev)
      ) {
        return null
      }
      const r = this.revokeSeq(v)
      if (r !== undefined && r < regSeq) return null
      nodes.push({ id: v, pub: k })
      cur = listed.dev
    }
    return null
  }

  chainLogged(d: DeviceRecord, members: CircleMember[]): boolean {
    return this.walkChain(d, members) !== null
  }

  epochLogged(circleId: string, r: EpochRecord): boolean {
    const e = this.epochs.get(`${circleId}|${r.epoch}`)
    if (!e) return false
    let commitHex: string
    try {
      commitHex = hexOf(unb64(r.key_commitment))
    } catch {
      return false
    }
    return (
      e.action === r.action &&
      e.user_id === r.publisher_user_id &&
      e.actor_device_id === r.publisher_device_id &&
      e.actor_ed25519_pub === r.publisher_ed25519_pub &&
      e.ref === commitHex &&
      e.signature === r.signature
    )
  }
}

function hexOf(b: Uint8Array): string {
  let s = ''
  for (const x of b) s += x.toString(16).padStart(2, '0')
  return s
}

/** Verifies the whole log from entry 1 and indexes it; the pinned head still applies (rollback/fork). */
export async function syncLogFull(pinned: LogHead | null, fetchPage: LogFetcher): Promise<{ check: LogCheck; index?: LogIndex }> {
  const all: LogEntry[] = []
  const seen = new Set<number>()
  const c = await syncLog(null, async (after) => {
    const r = await fetchPage(after)
    for (const e of r.entries) {
      if (!seen.has(e.seq)) {
        seen.add(e.seq) // pages overlap by one entry; index each sequence number once
        all.push(e)
      }
    }
    return r
  })
  if (!c.ok) return { check: c }
  const index = new LogIndex()
  for (const e of all) index.add(e)
  if (index.conflict) return { check: bad('malformed', index.conflict) }
  if (pinned) {
    if (c.newHead!.seq < pinned.seq) return { check: bad('rollback', `the server log is shorter (${c.newHead!.seq}) than the one pinned (${pinned.seq})`) }
    const h = index.hashes.get(pinned.seq)
    if (h === undefined || h !== pinned.hash) return { check: bad('fork', `entry ${pinned.seq} is not the one pinned`) }
  }
  return { check: c, index }
}

export function findDevice(members: CircleMember[], deviceId: string): { dev: DeviceRecord; member: CircleMember } | null {
  for (const m of members) {
    const dev = m.devices.find((d) => d.device_id === deviceId)
    if (dev) return { dev, member: m }
  }
  return null
}

function usable(idx: LogIndex | null, members: CircleMember[], d: DeviceRecord): string | null {
  if (!idx) return 'no verified log'
  if (d.revoked_at || idx.isRevoked(d.device_id)) return 'device is revoked'
  if (d.kind === 'recovery') return 'recovery keys do not act in a circle'
  if (d.approved !== true) return 'device is not approved'
  if (!verifyRegistration(d)) return 'device registration does not verify'
  if (!idx.chainLogged(d, members)) return 'device registration is not in the verified log'
  return null
}

/** The key we know is genuine without trusting the server: the phone that approved this viewer/bridge. */
export interface Anchor {
  deviceId: string
  edPub: string
}

/**
 * Derives the trust anchor from our OWN registration response: it must be for this device, carry the
 * approval signature the user carried from the phone (not one the server chose), be vouched by the
 * approver the user named, and verify completely. The approver key is thereby bound to a signature
 * only the real phone could produce.
 */
export function pinApprover(rec: DeviceRecord, deviceId: string, approverId: string, approvalSig: Uint8Array): Anchor {
  let ok = false
  try {
    ok =
      rec.device_id === deviceId &&
      rec.registered_by_device_id === approverId &&
      rec.registered_by_device_id !== rec.device_id &&
      constEq(unb64(rec.registration_signature), approvalSig) &&
      verifyRegistration(rec)
  } catch {
    ok = false
  }
  if (!ok) throw new E2eeError("the server's record of this registration does not match the approval the phone gave")
  return { deviceId: approverId, edPub: rec.registered_by_ed25519_pub }
}

/** Everything a verifier knows: the verified log, the (server-served) members, our account and the pinned approver. */
export interface TrustCtx {
  index: LogIndex | null
  members: CircleMember[]
  /** Empty means "no own-account concept" (log-binding rules only). */
  ownUserId: string
  anchor: Anchor | null
}

export const TRUST_ANCHORED = 'anchored' // wrapped by a device of OUR account chaining to the approving phone
export const TRUST_MEMBER = 'member' // wrapped by another member: first-use trust, not verified by our phone

function anchored(t: TrustCtx, d: DeviceRecord): boolean {
  if (!t.anchor || !t.ownUserId || !t.index) return false
  const nodes = t.index.walkChain(d, t.members)
  if (!nodes) return false
  if (nodes.some((n) => n.id === t.anchor!.deviceId && n.pub === t.anchor!.edPub)) return true
  const ad = findDevice(t.members, t.anchor.deviceId)
  if (!ad || ad.dev.ed25519_pub !== t.anchor.edPub) return false
  const an = t.index.walkChain(ad.dev, t.members)
  if (!an) return false
  const ra = an[an.length - 1]!
  const rd = nodes[nodes.length - 1]!
  return ra.id === rd.id && ra.pub === rd.pub
}

/** Returns null when the sender may speak for the member, else the reason (fail closed). */
export function authorizeSender(t: TrustCtx, found: { dev: DeviceRecord; member: CircleMember } | null): string | null {
  if (!found) return 'sender is not in the circle state'
  if (found.dev.user_id !== found.member.user_id) return 'device belongs to another user than the member it is listed under'
  const why = usable(t.index, t.members, found.dev)
  if (why) return why
  if (t.ownUserId && found.dev.user_id === t.ownUserId && !anchored(t, found.dev)) {
    return 'a device of your own account that does not chain to the phone that approved this viewer'
  }
  return null
}

/** Returns {level} when a wrap addressed to us may be opened, else {error} (fail closed). */
export function authorizeWrap(
  t: TrustCtx,
  circleId: string,
  w: WrapRecord,
  rec: EpochRecord | undefined,
): { level: string; error?: undefined } | { error: string; level?: undefined } {
  const no = (error: string) => ({ error })
  if (!t.index || !rec) return no('no verified log or epoch record')
  if (!t.index.epochLogged(circleId, rec)) return no('epoch record is not in the verified log')
  const pub = findDevice(t.members, rec.publisher_device_id)
  if (!pub) return no('epoch publisher is not in the circle state')
  if (pub.dev.ed25519_pub !== rec.publisher_ed25519_pub || pub.dev.user_id !== rec.publisher_user_id || pub.member.user_id !== rec.publisher_user_id) {
    return no('epoch publisher key differs from the registered key')
  }
  if (pub.member.role !== 'admin') return no('epoch publisher is not a circle admin')
  const pr = usable(t.index, t.members, pub.dev)
  if (pr) return no(`epoch publisher: ${pr}`)
  const wr = findDevice(t.members, w.wrapper_device_id)
  if (!wr) return no('wrapper is not in the circle state')
  if (wr.dev.ed25519_pub !== w.wrapper_ed25519_pub || wr.dev.user_id !== wr.member.user_id) return no('wrapper key differs from the registered key')
  const wu = usable(t.index, t.members, wr.dev)
  if (wu) return no(`wrapper: ${wu}`)
  if (t.ownUserId && wr.dev.user_id === t.ownUserId) {
    return anchored(t, wr.dev) ? { level: TRUST_ANCHORED } : no('wrapper is a device of your own account that does not chain to the phone that approved this viewer')
  }
  if (wr.dev.user_id === rec.publisher_user_id) {
    if (t.ownUserId && pub.dev.user_id === t.ownUserId && !anchored(t, pub.dev)) return no('epoch publisher is of your own account but does not chain to the approving phone')
    return { level: TRUST_MEMBER }
  }
  return no("wrapper is neither the epoch publisher nor the recipient's own device")
}
