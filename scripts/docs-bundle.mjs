// Copies docs/ into backend/web/docs/ (embedded in the server binary with
// go:embed) and writes manifest.json (categories, titles, headings, search text).
//   node scripts/docs-bundle.mjs           write the bundle
//   node scripts/docs-bundle.mjs --check   fail if the committed bundle is stale
import fs from 'node:fs'
import path from 'node:path'
import { DOCS, OUT, ROOT, SHIP_EXT, clip, latestRelease, parseMarkdown, plainText, summaryOf, titleOf, walk } from './docs-lib.mjs'

const check = process.argv.includes('--check')
const files = walk(DOCS).filter((f) => SHIP_EXT.has(path.extname(f).toLowerCase()))
const nav = JSON.parse(fs.readFileSync(path.join(DOCS, 'nav.json'), 'utf8'))

const docs = new Map()
for (const f of files.filter((f) => f.endsWith('.md'))) {
  const src = fs.readFileSync(path.join(DOCS, f), 'utf8')
  const { headings } = parseMarkdown(src)
  docs.set(f, {
    path: f,
    title: titleOf(src, f),
    summary: clip(summaryOf(src) ?? ''),
    headings: headings.filter((h) => h.level >= 2 && h.level <= 3).map((h) => ({ text: h.text, slug: h.slug })),
    text: plainText(src).slice(0, 15000),
  })
}

const used = new Set()
const categories = nav.categories.map((c) => ({
  id: c.id,
  title: c.title,
  description: c.description,
  ...(c.icon ? { icon: c.icon } : {}),
  docs: c.items.map((p) => {
    const d = docs.get(p)
    if (!d) throw new Error(`docs/nav.json lists ${p}, which does not exist`)
    used.add(p)
    return d
  }),
}))
const rest = [...docs.keys()].filter((p) => !used.has(p) && p !== 'README.md').sort()
if (rest.length) {
  categories.push({
    id: 'more',
    title: 'More',
    description: 'Everything else in the docs folder.',
    docs: rest.map((p) => docs.get(p)),
  })
}
const changelog = fs.readFileSync(path.join(DOCS, 'CHANGELOG.md'), 'utf8')
for (const p of nav.popular ?? []) if (!docs.has(p)) throw new Error(`docs/nav.json popular lists ${p}, which does not exist`)
const manifest = { release: latestRelease(changelog), popular: nav.popular ?? [], categories }

const want = new Map()
for (const f of files) want.set(f, fs.readFileSync(path.join(DOCS, f)))
want.set('manifest.json', Buffer.from(JSON.stringify(manifest) + '\n'))

if (check) {
  const have = fs.existsSync(OUT) ? walk(OUT) : []
  const bad = []
  for (const [f, buf] of want) {
    const p = path.join(OUT, f)
    if (!fs.existsSync(p) || !fs.readFileSync(p).equals(buf)) bad.push(f)
  }
  for (const f of have) if (!want.has(f)) bad.push(`${f} (should not be there)`)
  if (bad.length) {
    console.error('backend/web/docs is out of date; run scripts/docs-check.sh --fix (or node scripts/docs-bundle.mjs):')
    for (const b of bad.slice(0, 20)) console.error('  ' + b)
    process.exit(1)
  }
  console.log(`docs bundle in sync (${want.size} files)`)
} else {
  fs.rmSync(OUT, { recursive: true, force: true })
  for (const [f, buf] of want) {
    const p = path.join(OUT, f)
    fs.mkdirSync(path.dirname(p), { recursive: true })
    fs.writeFileSync(p, buf)
  }
  console.log(`wrote ${want.size} files to ${path.relative(ROOT, OUT)}`)
}
