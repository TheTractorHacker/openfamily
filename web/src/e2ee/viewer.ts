// The browser viewer: pairing, key sync, verification and decryption of the
// ciphertext a Private circle relays. Everything here runs in the browser; the
// server sees public keys, wrapped (encrypted) circle keys and ciphertext only.
// Decrypted positions are held in memory and never written to storage.

import {
  ACT,
  E2eeError,
  b64,
  b64urlPadded,
  bindingMessage,
  digitGroups,
  fingerprint,
  fromUtf8,
  hex,
  logActionMessage,
  openItem,
  shortFingerprint,
  unb64,
  utf8,
} from './core.ts'
import type { IdentityMeta, KeyOps, Vault } from './keystore.ts'
import {
  type CircleMember,
  type DeviceRecord,
  type EpochRecord,
  type LogEntry,
  type LogHead,
  type LogIndex,
  type WrapRecord,
  authorizeSender,
  authorizeWrap,
  findDevice,
  openWrap,
  syncLogFull,
} from './verify.ts'

/** Thin HTTP seam (the real one adds auth and refresh; tests pass a fake). */
export interface Http {
  get<T>(path: string): Promise<T>
  post<T>(path: string, body: unknown): Promise<T>
  del<T>(path: string, body?: unknown): Promise<T>
}

export type ViewerKind = 'web' | 'service'

export interface PairingInfo {
  fingerprint: Uint8Array
  short: string
  digits: string
}

export function pairingInfo(ops: KeyOps): PairingInfo {
  const fp = fingerprint(ops.edPub, ops.xPub)
  return { fingerprint: fp, short: shortFingerprint(fp), digits: digitGroups(fp) }
}

/** The request code the user pastes into the phone ("Approve a viewer or bridge"). */
export async function buildRequestCode(meta: IdentityMeta, ops: KeyOps, kind: ViewerKind = 'web'): Promise<string> {
  const binding = await ops.sign(bindingMessage(meta.userId, meta.deviceId, ops.edPub, ops.xPub))
  const json = JSON.stringify({
    u: meta.userId,
    d: meta.deviceId,
    e: b64(ops.edPub),
    x: b64(ops.xPub),
    b: b64(binding),
    k: kind,
    n: meta.name.slice(0, 40),
  })
  return b64urlPadded(utf8(json))
}

export interface Approval {
  actorDeviceId: string
  signature: Uint8Array
}

export function parseApproval(code: string): Approval {
  try {
    const m = JSON.parse(fromUtf8(unb64(code))) as { a?: unknown; s?: unknown }
    if (typeof m.a !== 'string' || typeof m.s !== 'string') throw new Error('shape')
    const signature = unb64(m.s)
    if (signature.length !== 64) throw new Error('sig')
    return { actorDeviceId: m.a, signature }
  } catch {
    throw new E2eeError('that is not a valid approval code')
  }
}

/** Registers the viewer's PUBLIC keys, cross-signed by the approving phone. */
export async function registerViewer(http: Http, meta: IdentityMeta, ops: KeyOps, approval: Approval, kind: ViewerKind = 'web'): Promise<DeviceRecord> {
  const binding = await ops.sign(bindingMessage(meta.userId, meta.deviceId, ops.edPub, ops.xPub))
  return http.post<DeviceRecord>('/e2ee/devices', {
    device_id: meta.deviceId,
    kind,
    ed25519_pub: b64(ops.edPub),
    x25519_pub: b64(ops.xPub),
    signature: b64(binding),
    label: meta.name.slice(0, 40),
    actor_device_id: approval.actorDeviceId,
    log_signature: b64(approval.signature),
    reset: false,
    can_upload: false,
  })
}

/** Revokes this viewer's key on the server (self-signed, action revoke). */
export async function revokeSelf(http: Http, meta: IdentityMeta, ops: KeyOps): Promise<void> {
  const fp = fingerprint(ops.edPub, ops.xPub)
  const msg = logActionMessage(ACT.revoke, meta.userId, meta.deviceId, { subjectId: meta.deviceId, ref: fp })
  await http.del(`/e2ee/devices/${meta.deviceId}`, {
    actor_device_id: meta.deviceId,
    log_signature: b64(await ops.sign(msg)),
  })
}

// ------------------------------------------------------------------ state

export type { CircleMember }

export interface CircleState {
  circle_id: string
  mode: 'off' | 'private'
  epoch: number
  rekey_required: boolean
  members: CircleMember[]
  epochs: EpochRecord[]
}

export interface CircleSummary {
  id: string
  name: string
  e2ee_mode?: string
  e2ee_epoch?: number
}

export interface SyncReport {
  state: CircleState
  newKeys: number
  rejectedWraps: number
  heldEpochs: number[]
  /** This viewer's own record in the circle (undefined if revoked or not registered). */
  self?: DeviceRecord
  logHead?: LogHead
  logIndex?: LogIndex
}

export class LogProblemError extends E2eeError {
  constructor(public problem: string, detail: string) {
    super(`The key transparency log failed verification (${problem}): ${detail}`)
    this.name = 'LogProblemError'
  }
}

export interface SessionDeps {
  http: Http
  meta: IdentityMeta
  ops: KeyOps
  vault: Vault
  getPin(): Promise<LogHead | null>
  setPin(h: LogHead): Promise<void>
}

/** Verifies the whole transparency log (from entry 1, honouring the pinned head), pins the new head and returns the index. */
export async function verifyAndPinLog(d: Pick<SessionDeps, 'http' | 'getPin' | 'setPin'>): Promise<{ head: LogHead; index: LogIndex }> {
  const pinned = await d.getPin()
  const { check: c, index } = await syncLogFull(pinned, async (after) => {
    const r = await d.http.get<{ entries: LogEntry[]; head: LogHead }>(`/e2ee/log?after=${after}`)
    return { entries: r.entries ?? [], head: { seq: r.head.seq, hash: r.head.hash ?? '' } }
  })
  if (!c.ok || !index) throw new LogProblemError(c.problem ?? 'unknown', c.detail ?? '')
  await d.setPin(c.newHead!)
  return { head: c.newHead!, index }
}

/** Fetches circle state, verifies the log, and stores every circle key the wraps legitimately carry. */
export async function syncCircle(d: SessionDeps, circleId: string): Promise<SyncReport> {
  const { head: logHead, index: logIndex } = await verifyAndPinLog(d)
  const state = await d.http.get<CircleState>(`/circles/${circleId}/e2ee`)
  const self = state.members.flatMap((m) => m.devices).find((x) => x.device_id === d.meta.deviceId)
  let newKeys = 0
  let rejected = 0
  if (state.mode === 'private') {
    const wr = await d.http.get<{ wraps: WrapRecord[] }>(`/circles/${circleId}/e2ee/wraps?device_id=${d.meta.deviceId}`)
    for (const w of wr.wraps ?? []) {
      if (await d.vault.getCircleKey(circleId, w.epoch)) continue
      const why = authorizeWrap(logIndex, state.members, circleId, d.meta.userId, w, state.epochs.find((e) => e.epoch === w.epoch))
      if (why) {
        rejected++
        continue
      }
      try {
        const key = await openWrap(
          circleId,
          d.meta.deviceId,
          (p) => d.ops.ecdh(p),
          d.ops.xPub,
          w,
          state.epochs.find((e) => e.epoch === w.epoch),
        )
        await d.vault.putCircleKey(circleId, w.epoch, key)
        newKeys++
      } catch {
        rejected++
      }
    }
  }
  return { state, newKeys, rejectedWraps: rejected, heldEpochs: await d.vault.heldEpochs(circleId), self, logHead, logIndex }
}

// ------------------------------------------------------------------ items

export interface RelayedItem {
  circle_id: string
  id: number
  device_id: string
  seq: number
  purpose: string
  epoch: number
  size_bucket?: number
  ciphertext: string
}

export interface Point {
  userId: string
  name: string
  deviceId: string
  ts: number // ms
  lat: number
  lon: number
  acc?: number
  spd?: number
  bat?: number
  mo?: string
  /** 'fix' for a live position, 'history' for a sealed track chunk. */
  src: 'fix' | 'history'
}

export interface PrivateEvent {
  userId: string
  name: string
  ts: number
  kind: string
  action?: string
  place?: string
  note?: string
  lat?: number
  lon?: number
}

export type ItemResult =
  | { type: 'points'; points: Point[] }
  | { type: 'event'; event: PrivateEvent }
  | { type: 'ignored' }
  | { type: 'deferred'; reason: string }
  | { type: 'dropped'; reason: string }

const FUTURE_SKEW_MS = 10 * 60 * 1000
const DEDUPE_WINDOW = 512

function finite(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v)
}

function validLatLon(lat: unknown, lon: unknown): boolean {
  return finite(lat) && finite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180
}

/** Applies the phone's ChannelReceiver policy to relayed items of one circle. */
export class Receiver {
  private seen = new Map<string, Set<number>>()
  private topEpoch = new Map<string, number>()
  dropped = 0
  deferredCount = 0

  constructor(
    private circleId: string,
    private getKey: (epoch: number) => Promise<Uint8Array | null>,
    private state: () => CircleState,
    private now: () => number = () => Date.now(),
    private logIndex: () => LogIndex | null = () => null,
  ) {}

  private senderOf(deviceId: string): { dev: DeviceRecord; member: CircleMember } | null {
    return findDevice(this.state().members, deviceId)
  }

  async handle(it: RelayedItem): Promise<ItemResult> {
    const drop = (reason: string): ItemResult => {
      this.dropped++
      return { type: 'dropped', reason }
    }
    if (it.circle_id !== this.circleId) return drop('wrong circle')
    let payload: Uint8Array
    try {
      payload = unb64(it.ciphertext)
    } catch {
      return drop('bad encoding')
    }
    if (payload.length < 5 || payload[0] !== 1) return drop('bad payload')
    const epoch = new DataView(payload.buffer, payload.byteOffset).getUint32(1, false)
    if (epoch !== it.epoch) return drop('epoch mismatch')
    const key = await this.getKey(epoch)
    if (!key) {
      this.deferredCount++
      return { type: 'deferred', reason: 'key for this epoch not held yet' }
    }
    const sender = this.senderOf(it.device_id)
    if (!sender) {
      this.deferredCount++
      return { type: 'deferred', reason: 'sender not known' }
    }
    const { dev, member } = sender
    const idx = this.logIndex()
    const why = authorizeSender(idx, this.state().members, sender)
    if (why) {
      if (idx && why.includes('not in the verified log')) {
        this.deferredCount++
        return { type: 'deferred', reason: why } // may appear after the next log verification
      }
      return drop(why)
    }
    let opened
    try {
      opened = openItem(key, this.circleId, it.device_id, unb64(dev.ed25519_pub), it.purpose, it.seq, payload)
    } catch {
      return drop('does not open or verify')
    }
    if (opened.tsMs > this.now() + FUTURE_SKEW_MS) return drop('timestamp in the future')
    const top = this.topEpoch.get(it.device_id) ?? 0
    if (epoch < top) return drop('epoch rollback')
    let win = this.seen.get(it.device_id)
    if (!win) this.seen.set(it.device_id, (win = new Set()))
    if (win.has(opened.seq)) return { type: 'ignored' }
    win.add(opened.seq)
    if (win.size > DEDUPE_WINDOW) win.delete(win.values().next().value as number)
    this.topEpoch.set(it.device_id, Math.max(top, epoch))
    return this.interpret(it.purpose, opened.tsMs, opened.body, dev, member, it.device_id)
  }

  private interpret(purpose: string, ts: number, body: Uint8Array, dev: DeviceRecord, member: CircleMember, deviceId: string): ItemResult {
    let j: Record<string, unknown>
    try {
      j = JSON.parse(fromUtf8(body)) as Record<string, unknown>
    } catch {
      return { type: 'dropped', reason: 'bad body' }
    }
    const base = { userId: dev.user_id, name: member.name, deviceId }
    if (purpose === 'fix') {
      if (!validLatLon(j.lat, j.lon)) return { type: 'dropped', reason: 'bad coordinates' }
      return {
        type: 'points',
        points: [
          {
            ...base,
            ts,
            lat: j.lat as number,
            lon: j.lon as number,
            acc: finite(j.acc) ? j.acc : undefined,
            spd: finite(j.spd) ? j.spd : undefined,
            bat: finite(j.bat) ? j.bat : undefined,
            mo: typeof j.mo === 'string' ? j.mo : undefined,
            src: 'fix',
          },
        ],
      }
    }
    if (purpose === 'history') {
      const pts = Array.isArray(j.pts) ? (j.pts as unknown[]) : []
      const out: Point[] = []
      for (const p of pts) {
        if (!Array.isArray(p) || p.length < 3) continue
        const [t, lat, lon, acc] = p as unknown[]
        if (!finite(t) || !validLatLon(lat, lon)) continue
        out.push({ ...base, ts: t, lat: lat as number, lon: lon as number, acc: finite(acc) ? acc : undefined, src: 'history' })
      }
      return { type: 'points', points: out }
    }
    if (purpose === 'event') {
      return {
        type: 'event',
        event: {
          ...base,
          ts,
          kind: String(j.k ?? 'event'),
          action: typeof j.a === 'string' ? j.a : undefined,
          place: typeof j.name === 'string' ? j.name : undefined,
        },
      }
    }
    if (purpose === 'checkin') {
      return {
        type: 'event',
        event: {
          ...base,
          ts,
          kind: String(j.k ?? 'checkin'),
          note: typeof j.note === 'string' ? j.note : undefined,
          lat: validLatLon(j.lat, j.lon) ? (j.lat as number) : undefined,
          lon: validLatLon(j.lat, j.lon) ? (j.lon as number) : undefined,
        },
      }
    }
    return { type: 'ignored' }
  }
}

// ------------------------------------------------------------------ data model

/** In-memory decrypted view of one circle (never persisted). */
export class PositionBook {
  last = new Map<string, Point>()
  trails = new Map<string, Point[]>()
  events: PrivateEvent[] = []
  static readonly MAX_TRAIL = 20000

  addPoints(pts: Point[]) {
    for (const p of pts) {
      const prev = this.last.get(p.userId)
      if (!prev || p.ts >= prev.ts) this.last.set(p.userId, p)
      const t = this.trails.get(p.userId) ?? []
      t.push(p)
      if (t.length > PositionBook.MAX_TRAIL) t.splice(0, t.length - PositionBook.MAX_TRAIL)
      this.trails.set(p.userId, t)
    }
  }

  addEvent(e: PrivateEvent) {
    this.events.push(e)
    if (this.events.length > 500) this.events.splice(0, this.events.length - 500)
  }

  /** Trail sorted by time with duplicates (live fix and the same point inside a history chunk) removed. */
  trail(userId: string): Point[] {
    const seen = new Set<string>()
    return [...(this.trails.get(userId) ?? [])]
      .sort((a, b) => a.ts - b.ts)
      .filter((p) => {
        const k = `${p.ts}|${p.lat.toFixed(6)}|${p.lon.toFixed(6)}`
        if (seen.has(k)) return false
        seen.add(k)
        return true
      })
  }
}

export class DeviceRevokedError extends E2eeError {
  constructor() {
    super('This viewer has been revoked or is not approved for this circle.')
    this.name = 'DeviceRevokedError'
  }
}

export interface PullResult {
  handled: number
  deferred: RelayedItem[]
  cursor: number
}

/** Pulls all ciphertext after `after` and feeds it to the receiver. */
export async function pullItems(
  http: Http,
  deviceId: string,
  circleId: string,
  rx: Receiver,
  book: PositionBook,
  after = 0,
  onItem?: (r: ItemResult) => void,
): Promise<PullResult> {
  let cursor = after
  let handled = 0
  const deferred: RelayedItem[] = []
  for (let page = 0; page < 1000; page++) {
    let r: { items: RelayedItem[]; next_cursor: number; has_more: boolean }
    try {
      r = await http.get(
        `/circles/${circleId}/e2ee/items?after=${cursor}&as_device=${deviceId}&purpose=fix,history,event,checkin&limit=500`,
      )
    } catch (e) {
      if (e instanceof Error && /no approved device/i.test(e.message)) throw new DeviceRevokedError()
      throw e
    }
    for (const it of r.items) {
      const res = await rx.handle(it)
      applyResult(book, res)
      onItem?.(res)
      if (res.type === 'deferred') deferred.push(it)
      else handled++
    }
    cursor = r.next_cursor
    if (!r.has_more) break
  }
  return { handled, deferred, cursor }
}

export function applyResult(book: PositionBook, res: ItemResult): void {
  if (res.type === 'points') book.addPoints(res.points)
  else if (res.type === 'event') book.addEvent(res.event)
}

export const fingerprintHex = (ops: KeyOps): string => hex(fingerprint(ops.edPub, ops.xPub))
