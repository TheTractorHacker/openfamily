import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ago, haSnippets } from '../src/lib/haSnippets.ts'

const TOKEN = 'ofha_' + 'x'.repeat(43)

test('snippets embed the server address and the token exactly once per snippet that needs it', () => {
  const s = haSnippets('https://family.example.com', TOKEN)
  assert.deepEqual(s.map((x) => x.id), ['hacs', 'rest', 'automation'])
  for (const id of ['hacs', 'rest']) {
    const t = s.find((x) => x.id === id).text
    assert.ok(t.includes('https://family.example.com'), id)
    assert.equal(t.split(TOKEN).length - 1, 1, id)
  }
  assert.ok(!s.find((x) => x.id === 'automation').text.includes(TOKEN), 'automation example carries no secret')
})

test('the REST snippet points at the read-only members endpoint', () => {
  const t = haSnippets('http://192.168.1.5:8080', TOKEN).find((x) => x.id === 'rest').text
  assert.ok(t.includes('http://192.168.1.5:8080/integrations/ha/v1/members'))
  assert.ok(t.includes(`Authorization: "Bearer ${TOKEN}"`))
})

test('ago renders relative times and "never"', () => {
  assert.equal(ago(null), 'never')
  assert.equal(ago(new Date().toISOString()), 'just now')
  assert.equal(ago(new Date(Date.now() - 5 * 60_000).toISOString()), '5m ago')
  assert.equal(ago(new Date(Date.now() - 3 * 3600_000).toISOString()), '3h ago')
  assert.equal(ago(new Date(Date.now() - 2 * 86400_000).toISOString()), '2d ago')
})
