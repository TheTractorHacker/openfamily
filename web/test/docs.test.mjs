import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { parseMarkdown, parseInline, safeHref, slugify, headingsOf } from '../src/lib/markdown.ts'
import { changelogSection, latestChangelogSection, docFromHash, docHash, resolveDocAsset, resolveDocLink, searchDocs } from '../src/lib/docs.ts'
import { peopleNeedingUpdate, policyInWords } from '../src/lib/compat.ts'

test('headings get GitHub-style unique ids', () => {
  const b = parseMarkdown('# Title\n\n## Docker `compose` & more\n\n## Docker compose & more\n')
  assert.deepEqual(headingsOf(b).map((h) => h.id), ['title', 'docker-compose--more', 'docker-compose--more-1'])
  assert.equal(slugify('Hello, World!'), 'hello-world')
})

test('inline: code, bold, italic, links and images', () => {
  const c = parseInline('a **b** _c_ `d` [e](f.md#g) ![alt](x.png)')
  assert.deepEqual(c.map((i) => i.t), ['text', 'strong', 'text', 'em', 'text', 'code', 'text', 'link', 'text', 'img'])
})

test('raw HTML and dangerous links stay inert text', () => {
  const c = parseInline('<script>alert(1)</script> [x](javascript:alert(1)) [y](data:text/html,hi)')
  assert.ok(c.every((i) => i.t === 'text'))
  assert.equal(safeHref('javascript:alert(1)'), null)
  assert.equal(safeHref('https://example.com'), 'https://example.com')
  assert.equal(safeHref('../a.md'), '../a.md')
})

test('lists, tables, quotes and code fences', () => {
  const b = parseMarkdown('- one\n  - nested\n- two\n\n1. a\n2. b\n\n| h1 | h2 |\n| --- | --- |\n| x | y |\n\n> quote\n\n```bash\nls # not a heading\n```\n')
  assert.deepEqual(b.map((x) => x.t), ['list', 'list', 'table', 'quote', 'code'])
  assert.equal(b[0].items.length, 2)
  assert.equal(b[0].items[0].length, 2) // paragraph + nested list
  assert.equal(b[2].rows.length, 1)
  assert.equal(b[4].v, 'ls # not a heading')
})

test('link resolution inside docs, up to the repo and outside', () => {
  assert.deepEqual(resolveDocLink('user/chat.md', '../chat.md#api'), { kind: 'doc', path: 'chat.md', slug: 'api' })
  assert.deepEqual(resolveDocLink('user/chat.md', 'places.md'), { kind: 'doc', path: 'user/places.md', slug: '' })
  assert.deepEqual(resolveDocLink('user/chat.md', '#top'), { kind: 'doc', path: 'user/chat.md', slug: 'top' })
  assert.equal(resolveDocLink('user/chat.md', '../../README.md').kind, 'external')
  assert.match(resolveDocLink('user/chat.md', '../../README.md#x').href, /github\.com.*\/blob\/main\/README\.md#x/)
  assert.equal(resolveDocLink('a.md', 'https://x.org').kind, 'external')
  assert.equal(resolveDocAsset('user/chat.md', '../images/app/chat.png'), 'images/app/chat.png')
  assert.equal(docFromHash(docHash('user/chat.md', 'api')).slug, 'api')
})

test('search finds titles, headings and text', () => {
  const m = { release: 'v1', categories: [{ id: 'a', title: 'A', description: '', docs: [
    { path: 'x.md', title: 'Backups', headings: [{ text: 'Restore', slug: 'restore' }], text: 'copy the database off the machine' },
    { path: 'y.md', title: 'Chat', headings: [], text: 'messages for the family' }] }] }
  assert.equal(searchDocs(m, 'backup')[0].doc.path, 'x.md')
  assert.equal(searchDocs(m, 'restore')[0].heading.slug, 'restore')
  assert.equal(searchDocs(m, 'family messages')[0].doc.path, 'y.md')
  assert.deepEqual(searchDocs(m, 'zzz'), [])
})

test('changelog section for a version', () => {
  const md = '# C\n\n## Unreleased\n\nx\n\n## v0.22.1 (2026)\n\n- a\n\n## v0.22.0 (2026)\n\n- b\n'
  assert.match(changelogSection(md, 'v0.22.1'), /^## v0\.22\.1[\s\S]*- a$/)
  assert.match(changelogSection(md, '0.22.0'), /- b$/)
  assert.equal(changelogSection(md, 'abc1234'), null)
  assert.match(latestChangelogSection(md), /^## v0\.22\.1/)
})

test('app versions: plain-words policy and who needs a nudge', () => {
  const p = { min_supported_version: '0.18.0', latest_version: '0.22.0', window: ['0.18', '0.19', '0.20', '0.21', '0.22'], window_size: 5, source: 'window', env_min_supported: '', override: '', enforce_writes: false }
  assert.match(policyInWords(p), /0\.18 to 0\.22/)
  assert.match(policyInWords({ ...p, enforce_writes: true }), /refused/)
  assert.equal(peopleNeedingUpdate([{ status: 'ok' }, { status: 'required' }, { status: 'recommended' }]).length, 2)
})

test('docs links, images and the embedded copy are intact (scripts/docs-check.sh)', () => {
  assert.ok(existsSync(new URL('../../scripts/docs-check.mjs', import.meta.url)))
  const out = execFileSync('node', ['scripts/docs-check.mjs'], { cwd: new URL('../../', import.meta.url), encoding: 'utf8' })
  assert.match(out, /docs check OK/)
  execFileSync('node', ['scripts/docs-bundle.mjs', '--check'], { cwd: new URL('../../', import.meta.url) })
})
