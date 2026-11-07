// Shared helpers for scripts/docs-bundle.mjs and scripts/docs-check.mjs.
// Plain Node (no dependencies). Run through scripts/docs-check.sh.
import fs from 'node:fs'
import path from 'node:path'

export const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
export const DOCS = path.join(ROOT, 'docs')
export const OUT = path.join(ROOT, 'backend', 'web', 'docs')

// Folders that are not shipped inside the server (kept on GitHub only).
export const EXCLUDE_DIRS = new Set(['audits'])
export const SHIP_EXT = new Set(['.md', '.png', '.webp', '.jpg', '.jpeg', '.svg', '.json'])

/** GitHub-style heading slug. Keep in step with web/src/lib/markdown.ts. */
export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/`/g, '')
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .trim()
    .replace(/\s/g, '-')
}

export function walk(dir, rel = '') {
  const out = []
  for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const r = rel ? `${rel}/${e.name}` : e.name
    if (e.isDirectory()) {
      if (!rel && EXCLUDE_DIRS.has(e.name)) continue
      out.push(...walk(path.join(dir, e.name), r))
    } else out.push(r)
  }
  return out
}

/** Headings and the link/image targets of a markdown file, ignoring code. */
export function parseMarkdown(src) {
  const headings = []
  const links = []
  const seen = new Map()
  let fence = false
  const lines = src.split('\n')
  lines.forEach((line, i) => {
    if (/^\s*(```|~~~)/.test(line)) {
      fence = !fence
      return
    }
    if (fence) return
    const h = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line)
    if (h) {
      const text = h[2].replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[*_]/g, '')
      let slug = slugify(text)
      const n = seen.get(slug) ?? 0
      seen.set(slug, n + 1)
      if (n) slug = `${slug}-${n}`
      headings.push({ level: h[1].length, text, slug })
    }
    const stripped = line.replace(/`[^`]*`/g, '')
    for (const m of stripped.matchAll(/(!?)\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) {
      links.push({ image: m[1] === '!', alt: m[2], target: m[3], line: i + 1 })
    }
  })
  return { headings, links }
}

export function plainText(src) {
  let fence = false
  const out = []
  for (const line of src.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) {
      fence = !fence
      continue
    }
    out.push(
      line
        .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
        .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
        .replace(/^[#>\s|*+-]+/, '')
        .replace(/[`*_|]/g, ''),
    )
  }
  return out.join(' ').replace(/\s+/g, ' ').trim()
}

export function titleOf(src, fallback) {
  const m = /^#\s+(.+)$/m.exec(src)
  return m ? m[1].replace(/[`*_]/g, '').trim() : fallback
}

export function latestRelease(changelog) {
  const m = /^## (v\d+\.\d+\.\d+)/m.exec(changelog)
  return m ? m[1] : ''
}

/**
 * The one-line summary of a page: the first paragraph under the "# Title"
 * heading, as plain text (null when the page starts with a list, table, image
 * or code instead). Used in search results and on the category cards.
 */
export function summaryOf(src) {
  const lines = src.replace(/\r\n?/g, '\n').split('\n')
  let i = lines.findIndex((l) => /^#\s+\S/.test(l))
  if (i < 0) return null
  i++
  while (i < lines.length && !lines[i].trim()) i++
  const buf = []
  while (i < lines.length && lines[i].trim() && !/^(#{1,6}\s|\s*>|\s*```|\s*~~~|\s*\||\s*[-*+]\s|\s*\d+[.)]\s|!\[|<)/.test(lines[i])) buf.push(lines[i++].trim())
  if (!buf.length) return null
  return buf
    .join(' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[`*_]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Shortens a summary to about `max` characters at a word boundary. */
export function clip(text, max = 200) {
  if (text.length <= max) return text
  const cut = text.slice(0, max)
  return cut.slice(0, cut.lastIndexOf(' ') > 80 ? cut.lastIndexOf(' ') : max).replace(/[,;:\s]+$/, '') + '…'
}
