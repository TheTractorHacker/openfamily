import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { parseMarkdown, parseInline, safeHref, slugify, headingsOf, tocOf, plainOf } from '../src/lib/markdown.ts'
import { addRecent, changelogSection, latestChangelogSection, docFromHash, docHash, highlightParts, neighbours, resolveDocAsset, resolveDocLink, searchDocs, searchTerms } from '../src/lib/docs.ts'
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
  assert.equal(b[0].items[0].c.length, 2) // paragraph + nested list
  assert.equal(b[2].rows.length, 1)
  assert.equal(b[4].v, 'ls # not a heading')
})

test('XSS: raw HTML, event handlers and script URLs never become markup', () => {
  const evil = [
    '<img src=x onerror=alert(1)>',
    '<script>alert(1)</script>',
    '[a](javascript:alert(1))',
    '[a]( JaVaScRiPt:alert(1) )',
    '[a](vbscript:x) [b](data:text/html;base64,AAAA) [c](file:///etc/passwd)',
    '![x](javascript:alert(1))',
    '<a href="javascript:alert(1)">x</a>',
    '<iframe src=//evil></iframe>',
  ].join('\n\n')
  const flat = JSON.stringify(parseMarkdown(evil))
  assert.ok(!flat.includes('"t":"link","href":"javascript'), 'no javascript link')
  assert.ok(!/"href":"(vbscript|data|file)/i.test(flat))
  // raw tags survive only as plain text nodes
  const p = parseMarkdown('<img src=x onerror=alert(1)>')[0]
  assert.equal(p.t, 'p')
  assert.ok(p.c.every((i) => i.t === 'text'))
  assert.equal(plainOf(p.c), '<img src=x onerror=alert(1)>')
  assert.equal(safeHref('  JAVASCRIPT:alert(1)'), null)
  assert.equal(safeHref('//evil.example/x'), '//evil.example/x') // protocol-relative stays a link; the app opens external links with noopener
  // an autolink only accepts http(s)
  assert.deepEqual(parseInline('<javascript:alert(1)>').map((i) => i.t), ['text'])
  assert.deepEqual(parseInline('<https://example.org/a>').map((i) => i.t), ['link'])
  // headings and callouts cannot smuggle markup either
  const h = parseMarkdown('# <b onclick=x>hi</b>\n\n> **Note** <script>x</script>')
  assert.equal(h[0].t, 'h')
  assert.ok(h[0].c.every((i) => i.t === 'text'))
  assert.equal(h[1].t, 'callout')
})

test('callouts: Note, Tip, Warning, Important and GitHub style', () => {
  const b = parseMarkdown('> **Note** Plain note.\n\n> **Warning:** careful\n> more\n\n> **Tip**: handy\n\n> [!IMPORTANT]\n> read this\n\n> just a quote')
  assert.deepEqual(b.map((x) => x.t), ['callout', 'callout', 'callout', 'callout', 'quote'])
  assert.deepEqual(b.slice(0, 4).map((x) => x.kind), ['note', 'warning', 'tip', 'important'])
  assert.equal(plainOf(b[0].c[0].c).trim(), 'Plain note.')
  assert.equal(plainOf(b[1].c[0].c).trim(), 'careful more')
  assert.equal(plainOf(b[2].c[0].c).trim(), 'handy')
  assert.equal(plainOf(b[3].c[0].c).trim(), 'read this')
})

test('tables keep column alignment; task lists and ordered starts', () => {
  const t = parseMarkdown('| a | b | c | d |\n|:--|:--:|--:|---|\n| 1 | 2 | 3 | 4 |')[0]
  assert.deepEqual(t.align, ['left', 'center', 'right', null])
  const l = parseMarkdown('- [ ] open\n- [x] done\n- plain\n\n3. three\n4. four')
  assert.deepEqual(l[0].items.map((i) => i.task), ['open', 'done', undefined])
  assert.equal(plainOf(l[0].items[0].c[0].c), 'open')
  assert.equal(l[1].start, 3)
  assert.equal(parseInline('~~gone~~')[0].t, 'del')
})

test('an image alone in a paragraph is a figure with a caption', () => {
  const f = parseMarkdown('![Alt text](a.png "A caption")\n\n![Only alt](b.png)\n\ntext ![inline](c.png) text')
  assert.deepEqual(f.map((x) => x.t), ['figure', 'figure', 'p'])
  assert.equal(f[0].caption, 'A caption')
  assert.equal(f[1].caption, 'Only alt')
})

test('table of contents lists second and third level headings only', () => {
  const b = parseMarkdown('# Title\n\n## One\n\n### One a\n\n#### deep\n\n## Two\n\n```\n## not a heading\n```\n')
  assert.deepEqual(tocOf(b).map((h) => [h.level, h.id]), [[2, 'one'], [3, 'one-a'], [2, 'two']])
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
  assert.equal(docHash('user/chat.md', 'api'), '#/documents/user/chat.md#api')
  assert.deepEqual(docFromHash('#/documents/user/chat.md'), { path: 'user/chat.md', slug: '' })
  assert.deepEqual(docFromHash('#/documents/user/chat.md?s=api'), { path: 'user/chat.md', slug: 'api' }) // older links
  assert.deepEqual(docFromHash('#documents/user/chat.md#api'), { path: 'user/chat.md', slug: 'api' })
  assert.equal(docFromHash('#/documents/../secret.md'), null)
  assert.equal(docFromHash('#/dashboard'), null)
  // ../ cannot escape the docs folder: it becomes a GitHub link
  assert.equal(resolveDocLink('a.md', '../../../etc/passwd').kind, 'external')
  assert.equal(resolveDocLink('a.md', 'javascript:alert(1)').kind, 'external')
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

test('search ranks titles above text, shows summaries and highlights', () => {
  const m = { release: 'v1', categories: [{ id: 'a', title: 'A', description: '', docs: [
    { path: 'a/text.md', title: 'Unrelated', summary: 'About things', headings: [], text: 'you can restore a backup here' },
    { path: 'a/title.md', title: 'Backups', summary: 'Keep a copy of your data.', headings: [{ text: 'Restore', slug: 'restore' }], text: 'copy the database' },
    { path: 'a/sum.md', title: 'Other', summary: 'Everything about backup and restore', headings: [], text: 'x' }] }] }
  const r = searchDocs(m, 'backup')
  assert.equal(r[0].doc.path, 'a/title.md')
  assert.equal(r.length, 3)
  assert.equal(searchDocs(m, 'backup restore')[0].doc.path, 'a/title.md')
  assert.match(searchDocs(m, 'copy of your')[0].snippet, /Keep a copy/)
  assert.deepEqual(searchDocs(m, '   '), [])
  assert.deepEqual(searchTerms('  Lost  "phone" '), ['lost', 'phone'])
  assert.deepEqual(highlightParts('Backup the backups', ['backup']), [
    { v: 'Backup', hit: true }, { v: ' the ', hit: false }, { v: 'backup', hit: true }, { v: 's', hit: false }])
  assert.deepEqual(highlightParts('a.b', ['.']), [{ v: 'a', hit: false }, { v: '.', hit: true }, { v: 'b', hit: false }]) // regex characters are escaped
  assert.deepEqual(highlightParts('x', []), [{ v: 'x', hit: false }])
})

test('recent searches: newest first, no repeats, capped', () => {
  let l = []
  for (const q of ['one', 'two', 'ONE', 'three', 'x', 'four', 'five', 'six', 'seven']) l = addRecent(l, q)
  assert.deepEqual(l, ['seven', 'six', 'five', 'four', 'three', 'ONE'])
  assert.deepEqual(addRecent(['a b'], 'A B'), ['A B'])
})

test('previous and next stay inside the category', () => {
  const d = (p) => ({ path: p, title: p, headings: [], text: '' })
  const m = { release: 'v', categories: [{ id: 'a', title: 'A', description: '', docs: [d('1.md'), d('2.md'), d('3.md')] }, { id: 'b', title: 'B', description: '', docs: [d('4.md')] }] }
  assert.equal(neighbours(m, '2.md').prev.path, '1.md')
  assert.equal(neighbours(m, '2.md').next.path, '3.md')
  assert.equal(neighbours(m, '3.md').next, undefined)
  assert.equal(neighbours(m, '4.md').prev, undefined)
  assert.deepEqual(neighbours(m, 'zzz.md'), {})
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
