// Glue between the browser viewer (viewer.ts, keystore.ts) and the React page:
// owns the unlocked key holder, one connection per circle, the live socket and
// the in-memory decrypted position book. Nothing decrypted is persisted.

import { b64, hex, fingerprint } from './core.ts'
import {
  type CustodyMode,
  type IdentityMeta,
  IdbKV,
  type KV,
  type Unlocked,
  createIdentity,
  getPin,
  loadMeta,
  markRegistered,
  setPin,
  unlockIdentity,
  webCryptoSupported,
  wipeIdentity,
} from './keystore.ts'
import { newUuid } from './core.ts'
import {
  type PendingAccountKey,
  type StepUp,
  type VaultHttp,
  type VaultStatus,
  changeAccountPassphrase,
  deleteVault,
  newAccountKey,
  pushPin,
  saveAccountKey,
  unlockAccountKey,
  vaultStatus,
} from './accountAccess.ts'
import { newerPin } from './accountVault.ts'
import {
  type CircleState,
  type ItemResult,
  PositionBook,
  Receiver,
  type RelayedItem,
  type SyncReport,
  DeviceRevokedError,
  applyResult,
  buildRequestCode,
  parseApproval,
  pullItems,
  registerViewer,
  revokeSelf,
  syncCircle,
} from './viewer.ts'

export type Phase = 'idle' | 'syncing' | 'live' | 'error' | 'revoked' | 'waiting-for-key'

export interface CircleConn {
  circleId: string
  name: string
  phase: Phase
  error?: string
  state?: CircleState
  report?: SyncReport
  book: PositionBook
  cursor: number
  counts: { opened: number; dropped: number; deferred: number }
  lastUpdate?: number
}

type Listener = () => void

export class ViewerController {
  meta: IdentityMeta | null = null
  unlocked: Unlocked | null = null
  conns = new Map<string, CircleConn>()
  private rx = new Map<string, Receiver>()
  private deferred = new Map<string, RelayedItem[]>()
  private listeners = new Set<Listener>()
  private ws: WebSocket | null = null
  private wsTimer: ReturnType<typeof setTimeout> | null = null
  private closed = false

  /** Web access from any browser: server status, a key being set up, the in-memory DEK. */
  account: { status: VaultStatus | null; pending: PendingAccountKey | null; saved: boolean } = { status: null, pending: null, saved: false }
  private dek: Uint8Array | null = null
  private pinPushed = 0
  /** True while the unlocked key is the account-bound one (memory only). */
  get accountMode(): boolean {
    return this.meta?.mode === 'account'
  }

  constructor(
    private http: VaultHttp,
    private userId: string,
    private kv: KV = new IdbKV(),
    private tokenProvider: () => string | null = () => null,
  ) {}

  subscribe(l: Listener): () => void {
    this.listeners.add(l)
    return () => this.listeners.delete(l)
  }
  private emit() {
    this.listeners.forEach((l) => l())
  }

  static supportsDeviceMode = webCryptoSupported

  async init(): Promise<void> {
    this.meta = await loadMeta(this.kv, this.userId)
    await this.refreshAccount()
    this.emit()
  }

  // ---- web access from any browser (account-bound key, docs/design/WEB_VIEWER_ANYWHERE.md)

  async refreshAccount(): Promise<void> {
    try {
      this.account.status = await vaultStatus(this.http)
    } catch {
      this.account.status = null // older server or no access: the feature is simply not offered
    }
    this.emit()
  }

  /** Step 1: a new key in memory (nothing stored yet). Returns the request code for the phone. */
  async createAccountKey(name: string): Promise<string> {
    this.disconnectAll()
    const k = newAccountKey(this.userId, newUuid(), name)
    this.account.pending = k
    this.account.saved = false
    this.unlocked = { meta: k.meta, ops: k.ops, vault: k.vault }
    this.meta = k.meta
    this.emit()
    return buildRequestCode(k.meta, k.ops, 'web')
  }

  /** Step 3 (after register): seal under the vault passphrase and store on the server. */
  async saveAccountKey(passphrase: string, s: StepUp, avoid: string[] = []): Promise<void> {
    const k = this.account.pending
    if (!k || !this.meta?.registered || !this.meta.approver) throw new Error('approve the key on your phone first')
    this.dek = await saveAccountKey(this.http, { ...k, meta: this.meta }, this.meta.approver, passphrase, s, { avoid })
    k.seed.fill(0)
    this.account.pending = null
    this.account.saved = true
    await this.refreshAccount()
  }

  /** Opens the stored key in memory (password + 2FA, then the vault passphrase). */
  async unlockAccount(passphrase: string, s: StepUp): Promise<void> {
    const o = await unlockAccountKey(this.http, this.userId, passphrase, s)
    this.disconnectAll()
    this.closed = false
    this.unlocked = { meta: o.meta, ops: o.ops, vault: o.vault }
    this.meta = o.meta
    this.dek = o.dek
    this.account.saved = true
    // Start from the newer of this browser's pin and the server's sealed pin.
    const local = await getPin(this.kv, `acct:${this.userId}`)
    const best = newerPin(local, o.remotePin)
    if (best) await setPin(this.kv, `acct:${this.userId}`, best)
    this.pinPushed = o.remotePin?.seq ?? 0
    this.emit()
  }

  async changeAccountPassphrase(passphrase: string, s: StepUp, avoid: string[] = []): Promise<void> {
    if (!this.accountMode || !this.dek) throw new Error('unlock first')
    await changeAccountPassphrase(this.http, this.userId, this.dek, passphrase, s, { avoid })
    await this.refreshAccount()
  }

  /** Forgets the unlocked key, circle keys and DEK in this tab. The stored vault stays. */
  lock(): void {
    if (!this.accountMode) return
    this.disconnectAll()
    this.dek?.fill(0)
    this.dek = null
    this.unlocked = null
    this.meta = null
    this.account.pending = null
    void this.init()
  }

  /** Deletes the stored vault (the key must be revoked separately, see revoke()). */
  async deleteAccountVault(): Promise<void> {
    await deleteVault(this.http)
    await this.refreshAccount()
  }

  private pinKey(): string {
    return this.accountMode ? `acct:${this.userId}` : this.userId
  }

  private async savePin(h: { seq: number; hash: string }): Promise<void> {
    await setPin(this.kv, this.pinKey(), h)
    if (this.accountMode && this.dek && this.meta && h.seq > this.pinPushed) {
      try {
        await pushPin(this.http, this.dek, this.userId, this.meta.deviceId, h)
        this.pinPushed = h.seq
      } catch {
        // best effort: this browser still remembers the pin
      }
    }
  }

  /** Creates the keys. Returns the request code to paste into the phone. */
  async create(name: string, mode: CustodyMode, passphrase?: string): Promise<string> {
    const u = await createIdentity({ kv: this.kv, mode, userId: this.userId, deviceId: newUuid(), name, passphrase })
    this.unlocked = u
    this.meta = u.meta
    this.emit()
    return buildRequestCode(u.meta, u.ops, 'web')
  }

  async requestCode(): Promise<string> {
    if (!this.unlocked) throw new Error('unlock first')
    return buildRequestCode(this.unlocked.meta, this.unlocked.ops, 'web')
  }

  async unlock(passphrase?: string): Promise<void> {
    const u = await unlockIdentity(this.kv, this.userId, passphrase)
    if (!u) throw new Error('no viewer keys in this browser')
    this.unlocked = u
    this.meta = u.meta
    this.emit()
  }

  needsPassphrase(): boolean {
    return this.meta?.mode === 'passphrase' && !this.unlocked
  }

  fingerprint(): { hex: string } | null {
    if (!this.unlocked) return null
    return { hex: hex(fingerprint(this.unlocked.ops.edPub, this.unlocked.ops.xPub)) }
  }

  /** Registers the public keys with the approval code the phone produced. */
  async register(approvalCode: string): Promise<void> {
    if (!this.unlocked) throw new Error('unlock first')
    const { anchor } = await registerViewer(this.http, this.unlocked.meta, this.unlocked.ops, parseApproval(approvalCode), 'web')
    if (!this.accountMode) await markRegistered(this.kv, this.userId, anchor)
    this.meta = { ...this.unlocked.meta, registered: true, approver: anchor }
    this.unlocked.meta = this.meta
    this.emit()
  }

  async revoke(): Promise<void> {
    if (!this.unlocked) throw new Error('unlock first')
    const account = this.accountMode
    await revokeSelf(this.http, this.unlocked.meta, this.unlocked.ops)
    if (account) {
      // The server deletes the vault with the key; delete explicitly too (idempotent).
      await deleteVault(this.http).catch(() => undefined)
      this.lock()
      return
    }
    await this.forget()
  }

  /** Removes the keys from this browser (does not revoke on the server). */
  async forget(): Promise<void> {
    if (this.accountMode) {
      this.lock() // an account key lives on the server, not in this browser
      return
    }
    this.disconnectAll()
    await wipeIdentity(this.kv, this.userId)
    this.unlocked = null
    this.meta = null
    this.emit()
  }

  private conn(circleId: string, name: string): CircleConn {
    let c = this.conns.get(circleId)
    if (!c) {
      c = { circleId, name, phase: 'idle', book: new PositionBook(), cursor: 0, counts: { opened: 0, dropped: 0, deferred: 0 } }
      this.conns.set(circleId, c)
    }
    return c
  }

  async connect(circleId: string, name: string): Promise<void> {
    const u = this.unlocked
    if (!u) throw new Error('unlock first')
    this.closed = false
    const c = this.conn(circleId, name)
    c.phase = 'syncing'
    c.error = undefined
    this.emit()
    try {
      const rep = await syncCircle(
        {
          http: this.http,
          meta: u.meta,
          ops: u.ops,
          vault: u.vault,
          getPin: () => getPin(this.kv, this.pinKey()),
          setPin: (h) => this.savePin(h),
        },
        circleId,
      )
      c.report = rep
      c.state = rep.state
      if (!rep.self) throw new DeviceRevokedError()
      let rx = this.rx.get(circleId)
      if (!rx) {
        rx = new Receiver(
          circleId,
          (e) => u.vault.getCircleKey(circleId, e),
          () => this.conns.get(circleId)!.state!,
          undefined,
          () => this.conns.get(circleId)?.report?.logIndex ?? null,
          () => ({ ownUserId: this.userId, anchor: this.meta?.approver ?? null }),
        )
        this.rx.set(circleId, rx)
      }
      if (rep.heldEpochs.length === 0) {
        c.phase = 'waiting-for-key'
        this.scheduleResync(c)
        this.emit()
        return
      }
      const pre = this.deferred.get(circleId) ?? []
      this.deferred.set(circleId, [])
      for (const it of pre) this.applyItem(c, await rx.handle(it), it)
      const r = await pullItems(this.http, u.meta.deviceId, circleId, rx, c.book, c.cursor, (res) => this.countOnly(c, res))
      c.cursor = r.cursor
      this.deferred.set(circleId, [...(this.deferred.get(circleId) ?? []), ...r.deferred])
      c.counts.deferred = this.deferred.get(circleId)!.length
      c.phase = 'live'
      c.lastUpdate = Date.now()
      this.openSocket()
    } catch (e) {
      if (e instanceof DeviceRevokedError) c.phase = 'revoked'
      else c.phase = 'error'
      c.error = e instanceof Error ? e.message : String(e)
    }
    this.emit()
  }

  private countOnly(c: CircleConn, res: ItemResult) {
    if (res.type === 'points' || res.type === 'event') c.counts.opened++
    else if (res.type === 'dropped') c.counts.dropped++
  }

  private applyItem(c: CircleConn, res: ItemResult, it?: RelayedItem) {
    this.countOnly(c, res)
    applyResult(c.book, res)
    if (res.type === 'deferred' && it) {
      const d = this.deferred.get(c.circleId) ?? []
      d.push(it)
      this.deferred.set(c.circleId, d)
      c.counts.deferred = d.length
      this.scheduleResync(c)
    }
    c.lastUpdate = Date.now()
  }

  private resyncTimers = new Map<string, ReturnType<typeof setTimeout>>()
  private scheduleResync(c: CircleConn) {
    if (this.resyncTimers.has(c.circleId)) return
    this.resyncTimers.set(
      c.circleId,
      setTimeout(() => {
        this.resyncTimers.delete(c.circleId)
        void this.connect(c.circleId, c.name)
      }, 12000),
    )
  }

  // ---- live socket

  private openSocket() {
    if (this.ws || this.closed) return
    const token = this.tokenProvider()
    if (!token) return
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:'
    const ws = new WebSocket(`${proto}//${location.host}/ws/stream`, token)
    this.ws = ws
    ws.onmessage = (ev) => {
      let f: (RelayedItem & { type?: string }) | null = null
      try {
        f = JSON.parse(String(ev.data))
      } catch {
        return
      }
      if (!f || f.type !== 'e2ee_item') return
      const c = this.conns.get(f.circle_id)
      const rx = this.rx.get(f.circle_id)
      if (!c || !rx) return
      void rx.handle(f).then((res) => {
        this.applyItem(c, res, f!)
        if (f!.id > c.cursor) c.cursor = f!.id
        this.emit()
      })
    }
    ws.onclose = () => {
      this.ws = null
      if (this.closed || this.conns.size === 0) return
      this.wsTimer = setTimeout(() => {
        // Resume from each circle's cursor, then reopen the socket.
        for (const c of this.conns.values()) if (c.phase === 'live') void this.connect(c.circleId, c.name)
      }, 5000)
    }
    ws.onerror = () => ws.close()
  }

  disconnectAll() {
    this.closed = true
    if (this.wsTimer) clearTimeout(this.wsTimer)
    this.resyncTimers.forEach((t) => clearTimeout(t))
    this.resyncTimers.clear()
    this.ws?.close()
    this.ws = null
    this.conns.clear()
    this.rx.clear()
    this.deferred.clear()
    this.emit()
  }

  dispose() {
    this.disconnectAll()
    this.dek?.fill(0)
    this.dek = null
    this.unlocked = null
    this.listeners.clear()
  }

  b64Pub(): string | null {
    return this.unlocked ? b64(this.unlocked.ops.edPub) : null
  }
}
