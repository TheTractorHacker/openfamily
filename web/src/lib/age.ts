// age X25519 key pair generation in the browser. The private key is created
// here and shown once; it is never sent to the server. Format: bech32 (BIP-173
// checksum without the 90-character limit) with HRP "age" for the recipient and
// "AGE-SECRET-KEY-" (upper-cased) for the identity, as in https://age-encryption.org.

import { x25519 } from '@noble/curves/ed25519.js'

const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

function polymod(values: number[]): number {
  let chk = 1
  for (const v of values) {
    const top = chk >>> 25
    chk = ((chk & 0x1ffffff) << 5) ^ v
    for (let i = 0; i < 5; i++) if ((top >>> i) & 1) chk ^= GEN[i]
  }
  return chk >>> 0
}

function hrpExpand(hrp: string): number[] {
  const out: number[] = []
  for (const c of hrp) out.push(c.charCodeAt(0) >> 5)
  out.push(0)
  for (const c of hrp) out.push(c.charCodeAt(0) & 31)
  return out
}

function toWords(data: Uint8Array): number[] {
  const out: number[] = []
  let acc = 0
  let bits = 0
  for (const b of data) {
    acc = (acc << 8) | b
    bits += 8
    while (bits >= 5) {
      bits -= 5
      out.push((acc >> bits) & 31)
    }
    acc &= (1 << bits) - 1
  }
  if (bits > 0) out.push((acc << (5 - bits)) & 31)
  return out
}

export function bech32Encode(hrp: string, data: Uint8Array): string {
  const words = toWords(data)
  const mod = polymod([...hrpExpand(hrp), ...words, 0, 0, 0, 0, 0, 0]) ^ 1
  const check: number[] = []
  for (let i = 0; i < 6; i++) check.push((mod >>> (5 * (5 - i))) & 31)
  return hrp + '1' + [...words, ...check].map((w) => CHARSET[w]).join('')
}

export interface AgeKeyPair {
  /** AGE-SECRET-KEY-1... : keep OFF the server. */
  privateKey: string
  /** age1... : the only value that goes into the server settings. */
  publicKey: string
}

/** Builds a key pair from 32 secret bytes (injectable for tests). */
export function ageKeyPairFromSecret(secret: Uint8Array): AgeKeyPair {
  if (secret.length !== 32) throw new Error('secret must be 32 bytes')
  const pub = x25519.getPublicKey(secret)
  return {
    privateKey: bech32Encode('age-secret-key-', secret).toUpperCase(),
    publicKey: bech32Encode('age', pub),
  }
}

export function generateAgeKeyPair(): AgeKeyPair {
  const secret = new Uint8Array(32)
  crypto.getRandomValues(secret)
  try {
    return ageKeyPairFromSecret(secret)
  } finally {
    secret.fill(0)
  }
}
