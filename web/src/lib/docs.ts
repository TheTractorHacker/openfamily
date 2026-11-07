// Helpers for the Documents page: link resolution, search, changelog sections.
// Pure functions (no React) so node --test can cover them.

import { REPO_URL } from './brand.ts'
export { REPO_URL }

export interface DocEntry {
  path: string
  title: string
  headings: { text: string; slug: string }[]
  text: string
}
export interface DocCategory {
  id: string
  title: string
  description: string
  docs: DocEntry[]
}
export interface DocsManifest {
  release: string
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

export const docHash = (path: string, slug = '') => `#/documents/${path}${slug ? `?s=${encodeURIComponent(slug)}` : ''}`

export function docFromHash(hash: string): { path: string; slug: string } | null {
  const m = /^#\/documents\/([^?]+)(?:\?(.*))?$/.exec(hash)
  if (!m) return null
  const slug = new URLSearchParams(m[2] ?? '').get('s') ?? ''
  return { path: decodeURIComponent(m[1]), slug }
}

export interface SearchHit {
  doc: DocEntry
  category: string
  heading?: { text: string; slug: string }
  snippet: string
  score: number
}

/** Client-side search over titles, headings and text. All terms must match. */
export function searchDocs(m: DocsManifest, query: string, limit = 30): SearchHit[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (!terms.length) return []
  const hits: SearchHit[] = []
  for (const c of m.categories) {
    for (const d of c.docs) {
      const title = d.title.toLowerCase()
      const heads = d.headings.map((h) => h.text.toLowerCase())
      const text = d.text.toLowerCase()
      if (!terms.every((t) => title.includes(t) || text.includes(t) || heads.some((h) => h.includes(t)))) continue
      let score = 0
      for (const t of terms) {
        if (title.includes(t)) score += 10
        if (heads.some((h) => h.includes(t))) score += 4
        if (text.includes(t)) score += 1
      }
      const hi = heads.findIndex((h) => terms.every((t) => h.includes(t)))
      const at = text.indexOf(terms[0])
      const snippet = at >= 0 ? (at > 40 ? '…' : '') + d.text.slice(Math.max(0, at - 40), at + 120) + '…' : d.text.slice(0, 120)
      hits.push({ doc: d, category: c.title, heading: hi >= 0 ? d.headings[hi] : undefined, snippet, score })
    }
  }
  return hits.sort((a, b) => b.score - a.score || a.doc.title.localeCompare(b.doc.title)).slice(0, limit)
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
