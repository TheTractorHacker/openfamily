import React from 'react'
import { ApiError, getDocImage, getDocText, getDocsManifest } from '../lib/api'
import { PageHeader } from '../components/patterns'
import { Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { useServerVersion } from '../lib/serverVersion'
import {
  changelogSection,
  latestChangelogSection,
  docFromHash,
  docHash,
  resolveDocAsset,
  resolveDocLink,
  searchDocs,
  type DocsManifest,
} from '../lib/docs'
import { parseMarkdown, type Block, type Inline } from '../lib/markdown'
import './pages.css'
import './DocsPage.css'

const errText = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : 'Request failed')

/** Docs images need the bearer token, so they are fetched and shown from a blob URL. */
function DocImage({ from, src, alt }: { from: string; src: string; alt: string }) {
  const [url, setUrl] = React.useState<string | null>(null)
  const [failed, setFailed] = React.useState(false)
  React.useEffect(() => {
    const p = resolveDocAsset(from, src)
    if (!p) {
      setFailed(true)
      return
    }
    let live = true
    let made: string | null = null
    getDocImage(p)
      .then((b) => {
        if (!live) return
        made = URL.createObjectURL(b)
        setUrl(made)
      })
      .catch(() => live && setFailed(true))
    return () => {
      live = false
      if (made) URL.revokeObjectURL(made)
    }
  }, [from, src])
  if (failed) return <span className="wb-doc-imgfail">[image: {alt}]</span>
  if (!url) return <span className="wb-doc-imgwait" aria-label={`Loading image: ${alt}`} />
  return <img src={url} alt={alt} loading="lazy" />
}

function Inlines({ from, c }: { from: string; c: Inline[] }) {
  return (
    <>
      {c.map((n, i) => {
        switch (n.t) {
          case 'text':
            return <React.Fragment key={i}>{n.v}</React.Fragment>
          case 'code':
            return <code key={i}>{n.v}</code>
          case 'strong':
            return <strong key={i}><Inlines from={from} c={n.c} /></strong>
          case 'em':
            return <em key={i}><Inlines from={from} c={n.c} /></em>
          case 'img':
            return <DocImage key={i} from={from} src={n.src} alt={n.alt} />
          case 'link': {
            const r = resolveDocLink(from, n.href)
            return r.kind === 'doc' ? (
              <a key={i} href={docHash(r.path, r.slug)}><Inlines from={from} c={n.c} /></a>
            ) : (
              <a key={i} href={r.href} target="_blank" rel="noopener noreferrer"><Inlines from={from} c={n.c} /></a>
            )
          }
        }
      })}
    </>
  )
}

function Blocks({ from, blocks }: { from: string; blocks: Block[] }) {
  return (
    <>
      {blocks.map((b, i) => {
        switch (b.t) {
          case 'h': {
            const Tag = `h${Math.min(b.level + 1, 6)}` as 'h2'
            return <Tag key={i} id={`doc-${b.id}`}><Inlines from={from} c={b.c} /></Tag>
          }
          case 'p':
            return <p key={i}><Inlines from={from} c={b.c} /></p>
          case 'quote':
            return <blockquote key={i}><Blocks from={from} blocks={b.c} /></blockquote>
          case 'code':
            return <pre key={i}><code>{b.v}</code></pre>
          case 'hr':
            return <hr key={i} />
          case 'list': {
            const L = b.ordered ? 'ol' : 'ul'
            return (
              <L key={i}>
                {b.items.map((it, j) => <li key={j}><Blocks from={from} blocks={it} /></li>)}
              </L>
            )
          }
          case 'table':
            return (
              <div className="wb-table-wrap" key={i}>
                <table className="wb-table">
                  <thead><tr>{b.head.map((h, j) => <th key={j}><Inlines from={from} c={h} /></th>)}</tr></thead>
                  <tbody>
                    {b.rows.map((r, j) => (
                      <tr key={j}>{r.map((c, k) => <td key={k}><Inlines from={from} c={c} /></td>)}</tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
        }
      })}
    </>
  )
}

/** Renders Markdown text. `from` is the docs-relative path used to resolve links and images. */
export function Markdown({ from, text }: { from: string; text: string }) {
  const blocks = React.useMemo(() => parseMarkdown(text), [text])
  return (
    <div className="wb-doc">
      <Blocks from={from} blocks={blocks} />
    </div>
  )
}

export function DocsPage() {
  const serverVersion = useServerVersion()
  const [manifest, setManifest] = React.useState<DocsManifest | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [query, setQuery] = React.useState('')
  const [loc, setLoc] = React.useState(() => docFromHash(window.location.hash))
  const [text, setText] = React.useState<string | null>(null)
  const [docError, setDocError] = React.useState<string | null>(null)
  const [changelog, setChangelog] = React.useState<string | null>(null)

  React.useEffect(() => {
    const on = () => setLoc(docFromHash(window.location.hash))
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])

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
      return
    }
    let live = true
    setText(null)
    setDocError(null)
    getDocText(path).then((t) => live && setText(t)).catch((e) => live && setDocError(errText(e)))
    return () => {
      live = false
    }
  }, [path])

  React.useEffect(() => {
    if (text === null) return
    if (loc?.slug) document.getElementById(`doc-${loc.slug}`)?.scrollIntoView()
    else document.getElementById('wb-content')?.scrollTo?.({ top: 0 })
  }, [text, loc?.slug])

  const hits = React.useMemo(() => (manifest ? searchDocs(manifest, query) : []), [manifest, query])
  const current = manifest?.categories.flatMap((c) => c.docs).find((d) => d.path === path)
  const notes = React.useMemo(() => {
    if (!changelog || !manifest) return null
    return (serverVersion && changelogSection(changelog, serverVersion)) || latestChangelogSection(changelog)
  }, [changelog, manifest, serverVersion])

  return (
    <div className="wb-page">
      <PageHeader
        title="Documents"
        subtitle={`The manual for your server${serverVersion ? ` (version ${serverVersion})` : ''}. It is stored on the server, so it works without internet.`}
      />
      {error && <ErrorState description={error} onRetry={load} />}
      {!manifest && !error && <div className="wb-page-loading"><Spinner /> Loading…</div>}
      {manifest && (
        <div className="wb-docs-layout">
          <nav className="wb-docs-nav" aria-label="Documentation">
            <label className="wb-field" htmlFor="docs-search">
              <span className="wb-label">Search the documents</span>
              <input
                id="docs-search"
                className="wb-input"
                type="search"
                placeholder="for example: backup, lost phone"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </label>
            {query.trim() ? (
              <ul className="wb-docs-results" aria-label="Search results">
                {hits.length === 0 && <li className="wb-help">Nothing found for “{query}”.</li>}
                {hits.map((h) => (
                  <li key={h.doc.path}>
                    <a href={docHash(h.doc.path, h.heading?.slug)} onClick={() => setQuery('')}>
                      {h.doc.title}
                      {h.heading ? ` › ${h.heading.text}` : ''}
                    </a>
                    <small>{h.category}: {h.snippet}</small>
                  </li>
                ))}
              </ul>
            ) : (
              manifest.categories.map((c) => (
                <details key={c.id} open={c.docs.some((d) => d.path === path) || c.id === 'start' || !path}>
                  <summary>{c.title}</summary>
                  <ul>
                    {c.docs.map((d) => (
                      <li key={d.path}>
                        <a href={docHash(d.path)} aria-current={d.path === path ? 'page' : undefined}>{d.title}</a>
                      </li>
                    ))}
                  </ul>
                </details>
              ))
            )}
          </nav>
          <section className="wb-docs-main" aria-live="polite">
            {!path && (
              <>
                <Card>
                  <h3 className="wb-settings-title">What is new in this server version</h3>
                  {notes ? (
                    <Markdown from="CHANGELOG.md" text={notes.replace(/^## /, '### ')} />
                  ) : (
                    <p className="wb-help">No release notes found for this version. See the full list in <a href={docHash('CHANGELOG.md')}>the changelog</a>.</p>
                  )}
                </Card>
                <div className="wb-docs-cats">
                  {manifest.categories.map((c) => (
                    <Card key={c.id}>
                      <h3 className="wb-settings-title">{c.title}</h3>
                      <p className="wb-help">{c.description}</p>
                      <ul>
                        {c.docs.slice(0, 6).map((d) => (
                          <li key={d.path}><a href={docHash(d.path)}>{d.title}</a></li>
                        ))}
                      </ul>
                    </Card>
                  ))}
                </div>
              </>
            )}
            {path && docError && <EmptyState title="This page is not in the documents" description={docError} />}
            {path && !docError && text === null && <div className="wb-page-loading"><Spinner /> Loading…</div>}
            {path && text !== null && (
              <Card>
                <p className="wb-docs-crumb"><a href="#/documents">All documents</a>{current ? ` › ${current.title}` : ''}</p>
                <Markdown from={path} text={text} />
              </Card>
            )}
          </section>
        </div>
      )}
    </div>
  )
}
