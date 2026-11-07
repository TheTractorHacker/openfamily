// Helpers for the Documents page: link resolution, search, changelog sections.
// Pure functions (no React) so node --test can cover them.

import { REPO_URL } from './brand.ts'
export { REPO_URL }

export interface DocEntry {
  path: string
  title: string
  /** One-line summary: the first paragraph under the page title. */
  summary?: string
  headings: { text: string; slug: string }[]
  text: string
}
export interface DocCategory {
  id: string
  title: string
  description: string
  /** Icon name from docs/nav.json (see DocIcon in the Documents page). */
  icon?: string
  docs: DocEntry[]
}
export interface DocsManifest {
  release: string
  /** Docs-relative paths shown as "Popular" on the landing page. */
  popular?: string[]
  categories: DocCategory[]
}

export type ResolvedLink =
  | { kind: 'doc'; path: string; slug: string }
  | { kind: 'external'; href: string }

/** Resolve `target` (as written in a doc) relative to the doc at `from` (docs-relative path). */
export function resolveDocLink(from: string, target: string): ResolvedLink {
  if (/^[a-z][a-z0-9+.-]*:/i.test(target)) return { kind: 'external', href: target }
  const [rawPath, slug = ''] = target.split('#')
  const parts = from.split('/').slice(0, -1)
  for (const seg of (rawPath || from.split('/').pop() || '').split('/')) {
    if (seg === '..') parts.pop()
    else if (seg && seg !== '.') parts.push(seg)
  }
  // Climbed above docs/: point at the file on GitHub.
  if (rawPath && rawPath.split('/').filter((s) => s === '..').length > from.split('/').length - 1) {
    const up = rawPath.split('/').filter((s) => s !== '..' && s !== '.' && s).join('/')
    return { kind: 'external', href: `${REPO_URL}/blob/main/${up}${slug ? '#' + slug : ''}` }
  }
  const path = rawPath ? parts.join('/') : from
  if (!/\.md$/i.test(path)) {
    return { kind: 'external', href: `${REPO_URL}/blob/main/docs/${path}` }
  }
  return { kind: 'doc', path, slug }
}

/** Docs-relative path of an image referenced from `from`. */
export function resolveDocAsset(from: string, src: string): string | null {
  if (/^[a-z][a-z0-9+.-]*:/i.test(src)) return null
  const r = resolveDocLink(from.replace(/[^/]*$/, 'x.md'), src)
  return r.kind === 'doc' ? r.path : r.kind === 'external' && r.href.includes('/blob/main/docs/') ? r.href.split('/blob/main/docs/')[1] : null
}

/** In-app route for a doc: `#/documents/<path>` plus `#<heading>` for a deep link. */
export const docHash = (path: string, slug = '') =>
  `#/documents/${path.split('/').map(encodeURIComponent).join('/')}${slug ? `#${encodeURIComponent(slug)}` : ''}`

/** Reads `#/documents/<path>#heading`, the older `?s=heading` form and `#documents/<path>`. */
export function docFromHash(hash: string): { path: string; slug: string } | null {
  const m = /^#\/?documents\/([^?#]+)(?:\?([^#]*))?(?:#(.*))?$/.exec(hash)
  if (!m) return null
  const safe = (v: string) => {
    try {
      return decodeURIComponent(v)
    } catch {
      return v
    }
  }
  const slug = m[3] ? safe(m[3]) : (new URLSearchParams(m[2] ?? '').get('s') ?? '')
  const path = safe(m[1])
  if (path.split('/').includes('..')) return null
  return { path, slug }
}

export interface SearchHit {
  doc: DocEntry
  category: string
  heading?: { text: string; slug: string }
  snippet: string
  score: number
}

export const searchTerms = (query: string) =>
  query
    .toLowerCase()
    .split(/\s+/)
    .map((t) => t.replace(/^["']|["']$/g, ''))
    .filter(Boolean)

/**
 * Client-side search over titles, summaries, headings and text. Every term must
 * match somewhere. Ranking: title (more for a word at the start), headings,
 * summary, then body text; a whole-word match beats a part-word match.
 */
export function searchDocs(m: DocsManifest, query: string, limit = 30): SearchHit[] {
  const terms = searchTerms(query)
  if (!terms.length) return []
  const hits: SearchHit[] = []
  const word = (hay: string, t: string) => new RegExp(`(^|[^\\p{L}\\p{N}])${t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`, 'u').test(hay)
  for (const c of m.categories) {
    for (const d of c.docs) {
      const title = d.title.toLowerCase()
      const summary = (d.summary ?? '').toLowerCase()
      const heads = d.headings.map((h) => h.text.toLowerCase())
      const text = d.text.toLowerCase()
      const pathText = d.path.toLowerCase()
      let score = 0
      let ok = true
      for (const t of terms) {
        const inTitle = title.includes(t)
        const inHead = heads.some((h) => h.includes(t))
        const inSummary = summary.includes(t)
        const inText = text.includes(t)
        if (!inTitle && !inHead && !inSummary && !inText && !pathText.includes(t)) {
          ok = false
          break
        }
        if (inTitle) score += title.startsWith(t) ? 16 : word(title, t) ? 12 : 8
        if (inHead) score += heads.some((h) => word(h, t)) ? 6 : 4
        if (inSummary) score += 4
        if (inText) score += Math.min(3, 1 + Math.floor(text.split(t).length / 4))
        if (pathText.includes(t)) score += 1
      }
      if (!ok) continue
      const hi = heads.findIndex((h) => terms.every((t) => h.includes(t)))
      const loose = hi >= 0 ? hi : heads.findIndex((h) => terms.some((t) => h.includes(t)))
      const at = text.indexOf(terms.find((t) => text.includes(t)) ?? '')
      const body = d.text
      const snippet =
        at >= 0 && !(d.summary && terms.every((t) => summary.includes(t)))
          ? (at > 50 ? '…' : '') + body.slice(Math.max(0, at - 50), at + 130).trim() + '…'
          : (d.summary ?? body.slice(0, 140))
      hits.push({ doc: d, category: c.title, heading: loose >= 0 ? d.headings[loose] : undefined, snippet, score })
    }
  }
  return hits.sort((a, b) => b.score - a.score || a.doc.title.localeCompare(b.doc.title)).slice(0, limit)
}

/** Splits text into plain and matched parts for highlighting (never builds HTML). */
export function highlightParts(text: string, terms: string[]): { v: string; hit: boolean }[] {
  const ts = terms.filter(Boolean).map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  if (!ts.length || !text) return [{ v: text, hit: false }]
  const re = new RegExp(`(${ts.join('|')})`, 'gi')
  return text
    .split(re)
    .map((v, i) => ({ v, hit: i % 2 === 1 }))
    .filter((p) => p.v !== '')
}

/** Most recent first, no repeats, capped. */
export function addRecent(list: string[], q: string, max = 6): string[] {
  const t = q.trim()
  if (t.length < 2) return list
  return [t, ...list.filter((x) => x.toLowerCase() !== t.toLowerCase())].slice(0, max)
}

/** Neighbours of a page inside its category, for the previous and next links. */
export function neighbours(m: DocsManifest, path: string): { category?: DocCategory; prev?: DocEntry; next?: DocEntry } {
  for (const c of m.categories) {
    const i = c.docs.findIndex((d) => d.path === path)
    if (i >= 0) return { category: c, prev: c.docs[i - 1], next: c.docs[i + 1] }
  }
  return {}
}

/** The CHANGELOG.md section for a version ("v0.22.1" or "0.22.1"), or null. */
export function changelogSection(md: string, version: string): string | null {
  const want = version.trim().replace(/^v/, '')
  const re = /^## (.+)$/gm
  const marks = [...md.matchAll(re)]
  for (let i = 0; i < marks.length; i++) {
    if (marks[i][1].trim().replace(/^v/, '').split(/\s/)[0] === want) {
      const end = i + 1 < marks.length ? marks[i + 1].index! : md.length
      return md.slice(marks[i].index!, end).trim()
    }
  }
  return null
}

/** The newest released section ("## v0.22.1 ...", skipping "Unreleased"), or null. */
export function latestChangelogSection(md: string): string | null {
  const m = /^## v\d+\.\d+\.\d+.*$/m.exec(md)
  return m ? changelogSection(md, m[0].slice(3).trim().split(/\s/)[0]) : null
}
