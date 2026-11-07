import { test } from 'node:test'
import assert from 'node:assert/strict'
import { abiLabel, abiRank, formatSize, releaseSlots, shareUrl, shortSha } from '../src/lib/builds.ts'
import { browserSkewSeconds, groupChecks, overallBanner } from '../src/lib/systemChecks.ts'

const a = (name, kind, abi, extra = {}) => ({ name, kind, abi, size: 1048576 * 20, ...extra })

test('release slots sort APKs universal first and keep absent slots empty', () => {
  const rel = {
    tag_name: 'v0.24.1',
    assets: [
      a('b-arm64-v8a.apk', 'android_apk', 'arm64-v8a'),
      a('b.apk', 'android_apk', 'universal'),
      a('b.aab', 'android_aab'),
      a('b-x86_64.apk', 'android_apk', 'x86_64'),
      a('SHA256SUMS.txt', 'checksums'),
    ],
  }
  const s = releaseSlots(rel)
  assert.deepEqual(s.androidApks.map((x) => x.name), ['b.apk', 'b-arm64-v8a.apk', 'b-x86_64.apk'])
  assert.equal(s.aab.name, 'b.aab')
  assert.equal(s.ipa, undefined)
  assert.deepEqual(s.wear, [])
  assert.equal(s.checksums.name, 'SHA256SUMS.txt')
})

test('formatting helpers', () => {
  assert.equal(formatSize(0), '—')
  assert.equal(formatSize(undefined), '—')
  assert.equal(formatSize(20 * 1048576), '20 MB')
  assert.equal(formatSize(5 * 1048576), '5.0 MB')
  assert.equal(formatSize(2048), '2 KB')
  assert.equal(shortSha('abcdef0123456789'), 'abcdef012345')
  assert.equal(shortSha(undefined), '')
  assert.match(abiLabel('arm64-v8a'), /Most phones/)
  assert.match(abiLabel(undefined), /universal/)
  assert.ok(abiRank('universal') < abiRank('arm64-v8a'))
})

test('share link: stable server path for the latest, GitHub URL otherwise', () => {
  const x = a('b.apk', 'android_apk', 'universal', { download_url: 'https://github.com/x/b.apk' })
  assert.equal(shareUrl('https://srv.example/', x, '/app.apk'), 'https://srv.example/app.apk')
  assert.equal(shareUrl('https://srv.example', x, null), 'https://github.com/x/b.apk')
  assert.equal(shareUrl('https://srv.example', { name: 'q' }, null), '')
})

test('banner never says all good while a check is failing or warning', () => {
  assert.equal(overallBanner({ ok: 5, warn: 0, fail: 0, info: 3 }).tone, 'success')
  assert.equal(overallBanner({ ok: 5, warn: 2, fail: 0 }).tone, 'warning')
  const b = overallBanner({ ok: 5, warn: 2, fail: 1 })
  assert.equal(b.tone, 'danger')
  assert.match(b.text, /1 check failed and 2 need a look/)
  assert.equal(overallBanner(undefined).tone, 'success')
})

test('checks are grouped in order of first appearance', () => {
  const g = groupChecks([
    { id: '1', group: 'Server', title: '', status: 'ok', summary: '' },
    { id: '2', group: 'Backups', title: '', status: 'ok', summary: '' },
    { id: '3', group: 'Server', title: '', status: 'ok', summary: '' },
  ])
  assert.deepEqual(g.map((x) => [x.group, x.checks.length]), [['Server', 2], ['Backups', 1]])
})

test('browser clock skew', () => {
  assert.equal(browserSkewSeconds('2026-01-01T00:00:00Z', Date.parse('2026-01-01T00:05:00Z')), 300)
  assert.equal(browserSkewSeconds('nonsense', 5), 0)
})
