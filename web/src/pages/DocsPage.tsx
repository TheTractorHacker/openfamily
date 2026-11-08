import React from 'react'
import { ApiError, getDocText, getDocsManifest } from '../lib/api'
import { Button, EmptyState, ErrorState } from '../components/primitives'
import { useServerVersion } from '../lib/serverVersion'
import {
  REPO_URL,
  addRecent,
  changelogSection,
  docFromHash,
  docHash,
  highlightParts,
  latestChangelogSection,
  neighbours,
  searchDocs,
  searchTerms,
  type DocCategory,
  type DocEntry,
  type DocsManifest,
} from '../lib/docs'
import { parseMarkdown, tocOf } from '../lib/markdown'
import { DocIcon } from './DocsIcons'
import { Markdown } from './DocsMarkdown'
import './pages.css'
import './DocsPage.css'

// Other pages (App versions) render Markdown too.
export { Markdown }

const errText = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : 'Request failed')
const RECENT_KEY = 'orbitly.docs.recent'
const textCache = new Map<string, string>()

const reducedMotion = () => typeof window !== 'undefined' && !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
const scroller = () => document.getElementById('wb-content')

function loadRecent(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]')
    return Array.isArray(v) ? v.filter((x) => typeof x === 'string').slice(0, 6) : []
  } catch {
    return []
  }
}
function saveRecent(list: string[]) {
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(list))
  } catch {
    /* private mode: recent searches simply are not kept */
  }
}

function Highlight({ text, terms }: { text: string; terms: string[] }) {
  return (
    <>
      {highlightParts(text, terms).map((p, i) => (p.hit ? <mark key={i}>{p.v}</mark> : <React.Fragment key={i}>{p.v}</React.Fragment>))}
    </>
  )
}

// ---- Search box (client side, ranked, keyboard driven) ----

function DocsSearch({ manifest, inputRef }: { manifest: DocsManifest; inputRef: React.RefObject<HTMLInputElement> }) {
  const [query, setQuery] = React.useState('')
  const [focused, setFocused] = React.useState(false)
  const [active, setActive] = React.useState(0)
  const [recent, setRecent] = React.useState<string[]>(loadRecent)
  const wrap = React.useRef<HTMLDivElement>(null)
  const terms = React.useMemo(() => searchTerms(query), [query])
  const hits = React.useMemo(() => searchDocs(manifest, query, 8), [manifest, query])
  const showRecent = !query.trim() && recent.length > 0
  const rows = query.trim() ? hits.length : showRecent ? recent.length : 0
  const open = focused && (query.trim().length > 0 || showRecent)

  React.useEffect(() => setActive(0), [query])

  const remember = (q: string) => {
    const next = addRecent(recent, q)
    setRecent(next)
    saveRecent(next)
  }
  const go = (i: number) => {
    if (query.trim()) {
      const h = hits[i]
      if (!h) return
      remember(query)
      window.location.hash = docHash(h.doc.path, h.heading?.slug)
      setQuery('')
      setFocused(false)
      inputRef.current?.blur()
    } else if (recent[i]) {
      setQuery(recent[i])
    }
  }
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      if (rows) setActive((a) => (a + 1) % rows)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      if (rows) setActive((a) => (a - 1 + rows) % rows)
    } else if (e.key === 'Enter') {
      if (rows) {
        e.preventDefault()
        go(active)
      }
    } else if (e.key === 'Escape') {
      if (query) setQuery('')
      else inputRef.current?.blur()
      setFocused(false)
    }
  }
  const listId = 'docs-search-list'
  return (
    <div
      className="wb-docs-search"
      ref={wrap}
      onFocus={() => setFocused(true)}
      onBlur={(e) => {
        if (!wrap.current?.contains(e.relatedTarget as Node | null)) setFocused(false)
      }}
    >
      <label htmlFor="docs-search" className="wb-visually-hidden">Search the documents</label>
      <span className="wb-docs-search-icon"><DocIcon name="search" size={16} /></span>
      <input
        id="docs-search"
        ref={inputRef}
        className="wb-input wb-docs-search-input"
        type="search"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={open && rows ? `docs-opt-${active}` : undefined}
        autoComplete="off"
        placeholder="Search the documents (for example: backup, lost phone)"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onKeyDown={onKey}
      />
      <kbd className="wb-docs-search-key" aria-hidden="true">/</kbd>
      {open && (
        <ul id={listId} className="wb-docs-results" role="listbox" aria-label={query.trim() ? 'Search results' : 'Recent searches'}>
          {showRecent && (
            <>
              <li className="wb-docs-results-head" role="presentation">
                <span>Recent searches</span>
                <button
                  type="button"
                  className="wb-linkish"
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => {
                    setRecent([])
                    saveRecent([])
                  }}
                >
                  Clear
                </button>
              </li>
              {recent.map((r, i) => (
                <li
                  key={r}
                  id={`docs-opt-${i}`}
                  role="option"
                  aria-selected={i === active}
                  className={i === active ? 'is-active' : undefined}
                  onMouseEnter={() => setActive(i)}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => setQuery(r)}
                >
                  <DocIcon name="clock" size={14} /> {r}
                </li>
              ))}
            </>
          )}
          {query.trim() && hits.length === 0 && (
            <li className="wb-docs-noresult" role="presentation">
              Nothing found for “{query}”. Try a shorter word, or browse the topics on the left.
            </li>
          )}
          {query.trim() &&
            hits.map((h, i) => (
              <li
                key={h.doc.path}
                id={`docs-opt-${i}`}
                role="option"
                aria-selected={i === active}
                className={i === active ? 'is-active' : undefined}
                onMouseEnter={() => setActive(i)}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => go(i)}
              >
                <span className="wb-docs-hit-title">
                  <Highlight text={h.doc.title} terms={terms} />
                  {h.heading && (
                    <>
                      <span className="wb-docs-sep"> › </span>
                      <Highlight text={h.heading.text} terms={terms} />
                    </>
                  )}
                </span>
                <span className="wb-docs-hit-cat">{h.category}</span>
                <small className="wb-docs-hit-snip"><Highlight text={h.snippet} terms={terms} /></small>
              </li>
            ))}
        </ul>
      )}
    </div>
  )
}

// ---- Category tree (collapsible; a drawer on small screens) ----

function Tree({
  manifest,
  path,
  open,
  toggle,
}: {
  manifest: DocsManifest
  path: string | null
  open: Set<string>
  toggle: (id: string) => void
}) {
  return (
    <nav className="wb-docs-tree" aria-label="Documentation topics">
      <a className="wb-docs-tree-home" href="#/documents" aria-current={path ? undefined : 'page'}>
        <DocIcon name="book" size={16} /> All documents
      </a>
      {manifest.categories.map((c) => {
        const isOpen = open.has(c.id)
        return (
          <div key={c.id} className="wb-docs-tree-cat">
            <button
              type="button"
              className="wb-docs-tree-toggle"
              aria-expanded={isOpen}
              aria-controls={`docs-cat-${c.id}`}
              onClick={() => toggle(c.id)}
            >
              <DocIcon name="chevron" size={14} className="wb-docs-chev" />
              <span>{c.title}</span>
              <span className="wb-docs-count">{c.docs.length}</span>
            </button>
            {isOpen && (
              <ul id={`docs-cat-${c.id}`}>
                {c.docs.map((d) => (
                  <li key={d.path}>
                    <a href={docHash(d.path)} aria-current={d.path === path ? 'page' : undefined}>
                      {d.title}
                    </a>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )
      })}
    </nav>
  )
}

// ---- On this page ----

function Toc({ path, items, active }: { path: string; items: { level: 2 | 3; id: string; text: string }[]; active: string }) {
  return (
    <ol className="wb-docs-toc-list">
      {items.map((t) => (
        <li key={t.id} className={`lvl-${t.level}`}>
          <a href={docHash(path, t.id)} aria-current={active === t.id ? 'location' : undefined}>
            {t.text}
          </a>
        </li>
      ))}
    </ol>
  )
}

function useScrollSpy(ids: string[], dep: unknown): string {
  const [active, setActive] = React.useState('')
  React.useEffect(() => {
    setActive(ids[0] ?? '')
    const root = scroller()
    if (!ids.length) return
    let raf = 0
    const compute = () => {
      raf = 0
      const top = (root ? root.getBoundingClientRect().top : 0) + 96
      let cur = ids[0]
      for (const id of ids) {
        const el = document.getElementById(`doc-${id}`)
        if (el && el.getBoundingClientRect().top <= top) cur = id
      }
      if (root && root.scrollTop + root.clientHeight >= root.scrollHeight - 4) cur = ids[ids.length - 1]
      setActive(cur)
    }
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(compute)
    }
    const target: HTMLElement | Window = root ?? window
    target.addEventListener('scroll', onScroll, { passive: true })
    compute()
    return () => {
      target.removeEventListener('scroll', onScroll)
      if (raf) cancelAnimationFrame(raf)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dep])
  return active
}

// ---- Loading skeletons ----

function ArticleSkeleton() {
  return (
    <div className="wb-docs-skel" aria-busy="true" aria-label="Loading the page">
      <div className="wb-skel" style={{ width: '55%', height: 34 }} />
      <div className="wb-skel" style={{ width: '90%' }} />
      <div className="wb-skel" style={{ width: '80%' }} />
      <div className="wb-skel" style={{ width: '40%', height: 22, marginTop: 24 }} />
      <div className="wb-skel" style={{ width: '95%' }} />
      <div className="wb-skel" style={{ width: '88%' }} />
      <div className="wb-skel" style={{ width: '70%' }} />
      <div className="wb-skel" style={{ width: '100%', height: 96, marginTop: 12 }} />
    </div>
  )
}

function PageSkeleton() {
  return (
    <div className="wb-docs-layout" aria-busy="true">
      <div className="wb-docs-tree">
        {[1, 2, 3, 4, 5].map((i) => <div key={i} className="wb-skel" style={{ width: `${60 + ((i * 7) % 30)}%`, height: 18 }} />)}
      </div>
      <ArticleSkeleton />
    </div>
  )
}

// ---- Landing page ----

function DocCard({ d }: { d: DocEntry }) {
  return (
    <li>
      <a href={docHash(d.path)}>
        <span className="wb-docs-card-title">{d.title}</span>
        {d.summary && <span className="wb-docs-card-sum">{d.summary}</span>}
      </a>
    </li>
  )
}

function Landing({ manifest, notes, serverVersion }: { manifest: DocsManifest; notes: string | null; serverVersion: string | null }) {
  const all = React.useMemo(() => new Map(manifest.categories.flatMap((c) => c.docs).map((d) => [d.path, d])), [manifest])
  const popular = (manifest.popular ?? []).map((p) => all.get(p)).filter((d): d is DocEntry => !!d)
  const [expanded, setExpanded] = React.useState(false)
  const lines = notes ? notes.split('\n') : []
  const heading = lines[0]?.replace(/^#+\s*/, '') ?? ''
  const version = heading.split(/\s+/)[0] || manifest.release
  const date = heading.replace(version, '').trim()
  const body = lines.slice(1).join('\n').trim()
  return (
    <div className="wb-docs-landing">
      <section className="wb-docs-hero">
        <h1>Documents</h1>
        <p>
          The manual for your server{serverVersion ? ` (version ${serverVersion})` : ''}. It is stored on the server, so it works without internet.
          Press <kbd>/</kbd> to search.
        </p>
      </section>

      {popular.length > 0 && (
        <section aria-labelledby="docs-popular">
          <h2 id="docs-popular" className="wb-docs-h2"><DocIcon name="star" size={16} /> Popular</h2>
          <ul className="wb-docs-popular">
            {popular.map((d) => <DocCard key={d.path} d={d} />)}
          </ul>
        </section>
      )}

      <section aria-labelledby="docs-cats">
        <h2 id="docs-cats" className="wb-docs-h2">Browse by topic</h2>
        <div className="wb-docs-cats">
          {manifest.categories.map((c) => <CategoryCard key={c.id} c={c} />)}
        </div>
      </section>

      <section aria-labelledby="docs-new" className="wb-docs-new">
        <h2 id="docs-new" className="wb-docs-h2"><DocIcon name="sparkle" size={16} /> What’s new in {version}</h2>
        {notes ? (
          <>
            {date && <p className="wb-help">{date}</p>}
            <div className={expanded ? 'wb-docs-new-body is-open' : 'wb-docs-new-body'}>
              <Markdown from="CHANGELOG.md" text={body.replace(/^## /gm, '### ')} />
            </div>
            <div className="wb-docs-new-actions">
              <Button variant="ghost" size="sm" onClick={() => setExpanded((v) => !v)} aria-expanded={expanded}>
                {expanded ? 'Show less' : 'Show all of it'}
              </Button>
              <a href={docHash('CHANGELOG.md')}>Full changelog</a>
            </div>
          </>
        ) : (
          <p className="wb-help">No release notes found for this version. See the full list in <a href={docHash('CHANGELOG.md')}>the changelog</a>.</p>
        )}
      </section>
    </div>
  )
}

function CategoryCard({ c }: { c: DocCategory }) {
  const first = c.docs[0]
  return (
    <article className="wb-docs-cat-card">
      <header>
        <span className="wb-docs-cat-icon"><DocIcon name={c.icon ?? 'file'} size={20} /></span>
        <h3>{first ? <a href={docHash(first.path)}>{c.title}</a> : c.title}</h3>
      </header>
      <p>{c.description}</p>
      <ul>
        {c.docs.slice(0, 4).map((d) => (
          <li key={d.path}><a href={docHash(d.path)}>{d.title}</a></li>
        ))}
      </ul>
      {c.docs.length > 4 && <span className="wb-docs-more">and {c.docs.length - 4} more</span>}
    </article>
  )
}

// ---- The page ----

export function DocsPage() {
  const serverVersion = useServerVersion()
  const [manifest, setManifest] = React.useState<DocsManifest | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [loc, setLoc] = React.useState(() => docFromHash(window.location.hash))
  const [text, setText] = React.useState<string | null>(null)
  const [docError, setDocError] = React.useState<string | null>(null)
  const [changelog, setChangelog] = React.useState<string | null>(null)
  const [drawer, setDrawer] = React.useState(false)
  const [openCats, setOpenCats] = React.useState<Set<string>>(new Set(['start']))
  const searchRef = React.useRef<HTMLInputElement>(null)

  React.useEffect(() => {
    const on = () => {
      setLoc(docFromHash(window.location.hash))
      setDrawer(false)
    }
    window.addEventListener('hashchange', on)
    document.body.classList.add('wb-printing-docs')
    return () => {
      window.removeEventListener('hashchange', on)
      document.body.classList.remove('wb-printing-docs')
    }
  }, [])

  // "/" jumps to the search box, like most documentation sites.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return
      const t = e.target as HTMLElement | null
      if (t && (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || t.isContentEditable)) return
      if (document.querySelector('.wb-lightbox')) return
      e.preventDefault()
      searchRef.current?.focus()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  React.useEffect(() => {
    if (!drawer) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setDrawer(false)
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [drawer])

  const load = React.useCallback(() => {
    setError(null)
    getDocsManifest().then(setManifest).catch((e) => setError(errText(e)))
  }, [])
  React.useEffect(load, [load])

  React.useEffect(() => {
    getDocText('CHANGELOG.md').then(setChangelog).catch(() => {})
  }, [])

  const path = loc?.path ?? null
  React.useEffect(() => {
    if (!path) {
      setText(null)
      setDocError(null)
      return
    }
    let live = true
    setDocError(null)
    const cached = textCache.get(path)
    if (cached !== undefined) {
      setText(cached)
      return
    }
    setText(null)
    getDocText(path)
      .then((t) => {
        textCache.set(path, t)
        if (live) setText(t)
      })
      .catch((e) => live && setDocError(errText(e)))
    return () => {
      live = false
    }
  }, [path])

  const current = manifest?.categories.flatMap((c) => c.docs).find((d) => d.path === path)
  const nb = React.useMemo(() => (manifest && path ? neighbours(manifest, path) : {}), [manifest, path])

  // Keep the category of the open page expanded.
  React.useEffect(() => {
    if (nb.category) setOpenCats((s) => (s.has(nb.category!.id) ? s : new Set(s).add(nb.category!.id)))
  }, [nb.category])

  const blocks = React.useMemo(() => (text === null ? null : parseMarkdown(text)), [text])
  const toc = React.useMemo(() => (blocks ? tocOf(blocks) : []), [blocks])
  const active = useScrollSpy(React.useMemo(() => toc.map((t) => t.id), [toc]), blocks)

  // Deep links: scroll to the heading, or to the top of a new page.
  React.useEffect(() => {
    if (text === null) return
    const smooth = !reducedMotion()
    if (loc?.slug) {
      const el = document.getElementById(`doc-${loc.slug}`)
      if (el) {
        el.scrollIntoView({ block: 'start', behavior: smooth ? 'smooth' : 'auto' })
        return
      }
    }
    scroller()?.scrollTo?.({ top: 0 })
  }, [text, loc?.slug, path])

  React.useEffect(() => {
    document.title = current ? `${current.title} - Documents` : 'Documents'
  }, [current])

  const notes = React.useMemo(() => {
    if (!changelog || !manifest) return null
    return (serverVersion && changelogSection(changelog, serverVersion)) || latestChangelogSection(changelog)
  }, [changelog, manifest, serverVersion])

  const toggleCat = (id: string) =>
    setOpenCats((s) => {
      const n = new Set(s)
      if (!n.delete(id)) n.add(id)
      return n
    })

  if (error) {
    return (
      <div className="wb-docs">
        <ErrorState description={error} onRetry={load} />
      </div>
    )
  }
  if (!manifest) {
    return (
      <div className="wb-docs">
        <PageSkeleton />
      </div>
    )
  }

  const title = current?.title ?? ''
  return (
    <div className="wb-docs">
      <div className="wb-docs-top">
        <button
          type="button"
          className="wb-docs-menu-btn"
          onClick={() => setDrawer(true)}
          aria-expanded={drawer}
          aria-controls="docs-tree-pane"
        >
          <DocIcon name="menu" size={18} /> Topics
        </button>
        <DocsSearch manifest={manifest} inputRef={searchRef} />
      </div>

      <div className={`wb-docs-layout${drawer ? ' is-drawer-open' : ''}`}>
        <div className="wb-docs-scrim" onClick={() => setDrawer(false)} aria-hidden="true" />
        <aside id="docs-tree-pane" className="wb-docs-tree-pane" aria-label="Topics">
          <div className="wb-docs-drawer-head">
            <strong>Topics</strong>
            <button type="button" className="wb-docs-menu-btn" onClick={() => setDrawer(false)} aria-label="Close topics">
              <DocIcon name="close" size={18} />
            </button>
          </div>
          <Tree manifest={manifest} path={path} open={openCats} toggle={toggleCat} />
        </aside>

        <main className="wb-docs-main" aria-live="polite" key={path ?? 'home'}>
          {!path && <Landing manifest={manifest} notes={notes} serverVersion={serverVersion} />}
          {path && docError && (
            <EmptyState title="This page is not in the documents" description={`${docError}. Use the topics list or search to find what you need.`} />
          )}
          {path && !docError && blocks === null && <ArticleSkeleton />}
          {path && blocks && (
            <article className="wb-docs-article">
              <nav className="wb-docs-crumbs" aria-label="Breadcrumb">
                <ol>
                  <li><a href="#/documents">Documents</a></li>
                  {nb.category && <li>{nb.category.title}</li>}
                  {title && <li aria-current="page">{title}</li>}
                </ol>
              </nav>
              {toc.length > 1 && (
                <details className="wb-docs-toc-inline">
                  <summary>On this page</summary>
                  <Toc path={path} items={toc} active={active} />
                </details>
              )}
              <Markdown from={path} blocks={blocks} />
              <footer className="wb-docs-foot">
                {(nb.prev || nb.next) && (
                  <nav className="wb-docs-pager" aria-label="Previous and next page">
                    {nb.prev ? (
                      <a href={docHash(nb.prev.path)} rel="prev" className="is-prev">
                        <small><DocIcon name="arrowLeft" size={14} /> Previous</small>
                        <span>{nb.prev.title}</span>
                      </a>
                    ) : <span />}
                    {nb.next ? (
                      <a href={docHash(nb.next.path)} rel="next" className="is-next">
                        <small>Next <DocIcon name="arrowRight" size={14} /></small>
                        <span>{nb.next.title}</span>
                      </a>
                    ) : <span />}
                  </nav>
                )}
                <p className="wb-docs-source">
                  <a href={`${REPO_URL}/blob/main/docs/${path}`} target="_blank" rel="noopener noreferrer" className="wb-doc-ext">
                    View this page on GitHub
                  </a>
                </p>
              </footer>
            </article>
          )}
        </main>

        {path && blocks && toc.length > 1 && (
          <aside className="wb-docs-toc" aria-label="On this page">
            <h2>On this page</h2>
            <Toc path={path} items={toc} active={active} />
          </aside>
        )}
      </div>
    </div>
  )
}
