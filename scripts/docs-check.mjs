// Fails when a relative link, image or anchor in the docs is broken, when
// docs/nav.json names a missing file, or when the embedded copy is stale.
import fs from 'node:fs'
import path from 'node:path'
import { DOCS, ROOT, parseMarkdown, walk } from './docs-lib.mjs'

const mdFiles = [
  ...walk(DOCS).filter((f) => f.endsWith('.md')).map((f) => path.join('docs', f)),
  'README.md',
]
const errors = []
const cache = new Map()
const headingsOf = (abs) => {
  if (!cache.has(abs)) cache.set(abs, parseMarkdown(fs.readFileSync(abs, 'utf8')))
  return cache.get(abs)
}

for (const rel of mdFiles) {
  const abs = path.join(ROOT, rel)
  const { links } = headingsOf(abs)
  for (const l of links) {
    const t = l.target
    if (/^[a-z][a-z0-9+.-]*:/i.test(t) || t.startsWith('//')) continue // http, mailto...
    const [pathPart, frag] = t.split('#')
    const target = pathPart ? path.resolve(path.dirname(abs), decodeURIComponent(pathPart.split('?')[0])) : abs
    const where = `${rel}:${l.line}`
    if (!target.startsWith(ROOT) || !fs.existsSync(target)) {
      errors.push(`${where}: ${l.image ? 'image' : 'link'} target not found: ${t}`)
      continue
    }
    if (l.image && !l.alt.trim()) errors.push(`${where}: image without alt text: ${t}`)
    if (frag && target.endsWith('.md') && !fs.statSync(target).isDirectory()) {
      const slugs = new Set(headingsOf(target).headings.map((h) => h.slug))
      if (!slugs.has(frag.toLowerCase())) errors.push(`${where}: no heading #${frag} in ${path.relative(ROOT, target)}`)
    }
  }
}

const nav = JSON.parse(fs.readFileSync(path.join(DOCS, 'nav.json'), 'utf8'))
for (const c of nav.categories) for (const p of c.items) if (!fs.existsSync(path.join(DOCS, p))) errors.push(`docs/nav.json: ${p} does not exist`)

if (errors.length) {
  console.error(`docs check FAILED (${errors.length}):`)
  for (const e of errors) console.error('  ' + e)
  process.exit(1)
}
console.log(`docs check OK (${mdFiles.length} markdown files)`)
