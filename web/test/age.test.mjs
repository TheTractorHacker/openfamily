import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ageKeyPairFromSecret, generateAgeKeyPair } from '../src/lib/age.ts'

// Vector cross-checked with filippo.io/age: age.ParseX25519Identity(privateKey).Recipient() == publicKey.
test('age key pair matches the reference implementation', () => {
  const secret = new Uint8Array(32).map((_, i) => i + 1)
  assert.deepEqual(ageKeyPairFromSecret(secret), {
    privateKey: 'AGE-SECRET-KEY-1QYPQXPQ9QCRSSZG2PVXQ6RS0ZQG3YYC5Z5TPWXQERGD3C8G7RUSQGPQYEE',
    publicKey: 'age1q73he0q5yzfu3d64msd3p6rvksnrwjk3d2598mgtmlqt9wrdr37q2vrn72',
  })
})

test('generated keys have the right shape and differ each time', () => {
  const a = generateAgeKeyPair()
  const b = generateAgeKeyPair()
  assert.match(a.publicKey, /^age1[a-z0-9]{58}$/)
  assert.match(a.privateKey, /^AGE-SECRET-KEY-1[A-Z0-9]{58}$/)
  assert.notEqual(a.privateKey, b.privateKey)
})
