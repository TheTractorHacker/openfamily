// What the operator may know about a Private circle's server processing: counts
// only (docs/design/PRIVACY_PROCESSING.md 18.2). Nothing here can opt a member in
// or out; the circle admin sets the policy and each member sets their own lane
// on their phone.

import type { E2eeAdminCircle } from './api'

export type LanesTone = 'green' | 'orange' | 'grey' | 'red'

export interface LanesSummary {
  /** Short state for a badge. */
  label: string
  tone: LanesTone
  /** Members whose server may read them. */
  serverAssisted: number
  /** Members who keep data on their phone. */
  phoneOnly: number
  /** One plain sentence about what this means for the operator. */
  policy: string
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

export function lanesSummary(c: E2eeAdminCircle): LanesSummary {
  const server = Math.max(0, c.members_server_assisted ?? 0)
  const phone = Math.max(0, c.members_phone_only ?? 0)
  if (c.mode !== 'private') {
    return { label: 'Not private', tone: 'grey', serverAssisted: 0, phoneOnly: 0, policy: 'A normal circle: the server stores readable positions for every member.' }
  }
  if (c.legacy_trusted_server) {
    return {
      label: 'Old trusted-server mode',
      tone: 'orange',
      serverAssisted: server,
      phoneOnly: phone,
      policy: 'Old trusted-server mode: the server holds the circle key while every member allows it. A circle admin can upgrade it in the app.',
    }
  }
  if (!c.server_assist) {
    return {
      label: 'Phones only',
      tone: 'green',
      serverAssisted: 0,
      phoneOnly: phone + server,
      policy: 'Server assistance is off. All members keep their data on their phones; the server holds ciphertext only.',
    }
  }
  return {
    label: 'Server-assisted',
    tone: server > 0 ? 'orange' : 'grey',
    serverAssisted: server,
    phoneOnly: phone,
    policy:
      `Server assistance is on. ${plural(server, 'member allows', 'members allow')} the server to read their data; ` +
      `${plural(phone, 'member keeps', 'members keep')} data on their phone. Each member decides for themselves.`,
  }
}
