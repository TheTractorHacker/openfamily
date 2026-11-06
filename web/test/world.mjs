// A tiny in-memory "OpenFamily server + phones" for the viewer tests. Phones
// are played by core.ts helpers; the server is a fake Http that serves what the
// real one serves (public keys, signed log, wraps, ciphertext).
import { ed25519, x25519 } from '@noble/curves/ed25519.js'
import * as c from '../src/e2ee/core.ts'

export const CIRCLE = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
export const USER_A = '11111111-1111-4111-8111-111111111111'
export const USER_B = '22222222-2222-4222-8222-222222222222'

export function phone(seedByte, userId, deviceId) {
  const { edSeed, xSecret } = c.deriveIdentity(new Uint8Array(32).fill(seedByte))
  return { userId, deviceId, edSeed, xSecret, ed: c.edPublic(edSeed), x: c.xPublic(xSecret) }
}

export function deviceRecord(sub, { kind = 'device', actor = sub, approved = true, action = 1, tamper = false } = {}) {
  const fp = c.fingerprint(sub.ed, sub.x)
  const msg = c.logActionMessage(action, sub.userId, actor.deviceId, { subjectId: sub.deviceId, ref: fp })
  const rsig = ed25519.sign(msg, actor.edSeed)
  if (tamper) rsig[0] ^= 1
  return {
    device_id: sub.deviceId,
    user_id: sub.userId,
    kind,
    ed25519_pub: c.b64(sub.ed),
    x25519_pub: c.b64(sub.x),
    fingerprint: c.hex(fp),
    signature: c.b64(ed25519.sign(c.bindingMessage(sub.userId, sub.deviceId, sub.ed, sub.x), sub.edSeed)),
    registered_by_device_id: actor.deviceId,
    registered_by_ed25519_pub: c.b64(actor.ed),
    registration_action: action,
    registration_signature: c.b64(rsig),
    label: kind,
    approved,
    _msg: msg,
    _sig: rsig,
    _actor: actor,
  }
}

export class World {
  constructor() {
    this.A = phone(1, USER_A, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
    this.B = phone(2, USER_B, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    this.V = phone(9, USER_A, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd') // the viewer's keys (derived for test convenience)
    this.keys = new Map() // epoch -> key
    this.epochs = []
    this.devices = [] // device records
    this.log = []
    this.wraps = []
    this.items = []
    this.nextId = 1
    this.mode = 'private'
    this.epoch = 0
    this.revoked = false
    this.requests = []
  }

  appendLog(action, user, actor, { circle, subject, epoch = 0, ref, sig, msg }) {
    const prev = this.log.length ? c.unhex(this.log[this.log.length - 1].entry_hash) : c.GENESIS_HASH
    const seq = this.log.length + 1
    const entryHash = c.logEntryHash(prev, seq, msg, sig)
    this.log.push({
      seq, prev_hash: c.hex(prev), entry_hash: c.hex(entryHash), redacted: false, action,
      user_id: user, actor_device_id: actor.deviceId, actor_ed25519_pub: c.b64(actor.ed),
      circle_id: circle ?? null, subject_id: subject ?? null, epoch, ref: c.hex(ref), signature: c.b64(sig),
    })
  }

  register(sub, opts = {}) {
    const rec = deviceRecord(sub, opts)
    this.devices.push(rec)
    this.appendLog(rec.registration_action, sub.userId, rec._actor, { subject: sub.deviceId, ref: c.unhex(rec.fingerprint), sig: rec._sig, msg: rec._msg })
    return rec
  }

  publishEpoch(epoch, { commitmentOfOther } = {}) {
    const key = c.randomBytes(32)
    this.keys.set(epoch, key)
    const commit = c.keyCommitment(commitmentOfOther ?? key, CIRCLE, epoch)
    const action = epoch === 1 ? c.ACT.enable : c.ACT.epoch
    const msg = c.logActionMessage(action, USER_A, this.A.deviceId, { circleId: CIRCLE, epoch, ref: commit })
    const sig = ed25519.sign(msg, this.A.edSeed)
    this.appendLog(action, USER_A, this.A, { circle: CIRCLE, epoch, ref: commit, sig, msg })
    this.epochs.push({
      epoch, action, publisher_user_id: USER_A, publisher_device_id: this.A.deviceId,
      publisher_ed25519_pub: c.b64(this.A.ed), key_commitment: c.b64(commit), signature: c.b64(sig),
    })
    this.epoch = epoch
    return key
  }

  wrapTo(epoch, to, wrapper = this.A) {
    const aad = c.wrapAad(CIRCLE, epoch, to.deviceId, wrapper.deviceId)
    const blob = c.wrapWithRandomness(this.keys.get(epoch), to.x, aad, c.randomBytes(32), c.randomBytes(24))
    const sig = ed25519.sign(c.wrapSigMessage(CIRCLE, epoch, to.deviceId, wrapper.deviceId, blob), wrapper.edSeed)
    this.wraps.push({
      epoch, recipient_device_id: to.deviceId, wrapper_device_id: wrapper.deviceId,
      wrapper_ed25519_pub: c.b64(wrapper.ed), wrapped_key: c.b64(blob), signature: c.b64(sig),
    })
  }

  seal(sender, epoch, purpose, seq, tsMs, bodyObj, { key } = {}) {
    const payload = c.sealItem(key ?? this.keys.get(epoch), CIRCLE, epoch, sender.deviceId, sender.edSeed, purpose, seq, tsMs,
      c.utf8(JSON.stringify(bodyObj)), c.randomBytes(24))
    const it = { circle_id: CIRCLE, id: this.nextId++, device_id: sender.deviceId, seq, purpose, epoch, size_bucket: payload.length - 45, ciphertext: c.b64(payload) }
    this.items.push(it)
    return it
  }

  state() {
    const byUser = (u, name) => ({ user_id: u, name, role: 'admin', devices: this.devices.filter((d) => d.user_id === u).map(strip) })
    return {
      circle_id: CIRCLE, mode: this.mode, epoch: this.epoch, rekey_required: false,
      members: [byUser(USER_A, 'Alex'), byUser(USER_B, 'Bea')], epochs: this.epochs,
    }
  }

  http() {
    const w = this
    const h = {
      async get(path) {
        w.requests.push(path)
        if (path.startsWith('/e2ee/log')) {
          const after = Number(new URL('http://x' + path).searchParams.get('after'))
          const entries = w.log.filter((e) => e.seq > after).slice(0, 500)
          const last = w.log[w.log.length - 1]
          return { entries, head: { seq: last ? last.seq : 0, hash: last ? last.entry_hash : '' } }
        }
        if (path === `/circles/${CIRCLE}/e2ee`) return w.state()
        if (path.startsWith(`/circles/${CIRCLE}/e2ee/wraps`)) {
          const dev = new URL('http://x' + path).searchParams.get('device_id')
          return { wraps: w.wraps.filter((x) => x.recipient_device_id === dev) }
        }
        if (path.startsWith(`/circles/${CIRCLE}/e2ee/items`)) {
          if (w.revoked) throw new Error('no approved device key for this circle')
          const q = new URL('http://x' + path).searchParams
          const after = Number(q.get('after'))
          const limit = Number(q.get('limit'))
          const rows = w.items.filter((i) => i.id > after).slice(0, limit + 1)
          const more = rows.length > limit
          const out = rows.slice(0, limit)
          return { items: out, next_cursor: out.length ? out[out.length - 1].id : after, has_more: more }
        }
        throw new Error('unexpected GET ' + path)
      },
      async post(path, body) {
        w.requests.push('POST ' + path)
        w.lastPost = { path, body }
        return { ...body, device_id: body.device_id }
      },
      async del(path, body) {
        w.requests.push('DELETE ' + path)
        w.lastDelete = { path, body }
        return {}
      },
    }
    return h
  }
}

function strip(d) {
  const { _msg, _sig, _actor, ...rest } = d
  return rest
}

export { x25519 }
