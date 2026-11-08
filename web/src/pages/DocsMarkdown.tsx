import React from 'react'
import { getDocImage } from '../lib/api'
import { docHash, resolveDocAsset, resolveDocLink } from '../lib/docs'
import { parseMarkdown, type Block, type CalloutKind, type Inline } from '../lib/markdown'
import { DocIcon } from './DocsIcons'

// Images are fetched with the bearer token and shown from blob URLs. Several
// pages ask for the same picture, so finished downloads are remembered.
const imageCache = new Map<string, Promise<string>>()

function useDocImage(from: string, src: string) {
  const [url, setUrl] = React.useState<string | null>(null)
  const [failed, setFailed] = React.useState(false)
  React.useEffect(() => {
    const p = resolveDocAsset(from, src)
    if (!p) {
      setFailed(true)
      return
    }
    let live = true
    let job = imageCache.get(p)
    if (!job) {
      job = getDocImage(p).then((b) => URL.createObjectURL(b))
      imageCache.set(p, job)
      job.catch(() => imageCache.delete(p))
    }
    job.then((u) => live && setUrl(u)).catch(() => live && setFailed(true))
    return () => {
      live = false
    }
  }, [from, src])
  return { url, failed }
}

function Lightbox({ url, alt, caption, onClose }: { url: string; alt: string; caption: string; onClose: () => void }) {
  const closeRef = React.useRef<HTMLButtonElement>(null)
  React.useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    closeRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      } else if (e.key === 'Tab') {
        e.preventDefault() // the only control is the close button
        closeRef.current?.focus()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      prev?.focus?.()
    }
  }, [onClose])
  return (
    <div className="wb-lightbox" role="dialog" aria-modal="true" aria-label={`Image: ${alt}`} onClick={onClose}>
      <button ref={closeRef} type="button" className="wb-lightbox-close" onClick={onClose} aria-label="Close image">
        <DocIcon name="close" size={20} />
      </button>
      <figure onClick={(e) => e.stopPropagation()}>
        <img src={url} alt={alt} />
        {caption && <figcaption>{caption}</figcaption>}
      </figure>
    </div>
  )
}

function DocImage({ from, src, alt }: { from: string; src: string; alt: string }) {
  const { url, failed } = useDocImage(from, src)
  if (failed) return <span className="wb-doc-imgfail">[image: {alt}]</span>
  if (!url) return <span className="wb-doc-imgwait" role="img" aria-label={`Loading image: ${alt}`} />
  return <img src={url} alt={alt} loading="lazy" className="wb-doc-inline-img" />
}

function Figure({ from, src, alt, caption }: { from: string; src: string; alt: string; caption: string }) {
  const { url, failed } = useDocImage(from, src)
  const [open, setOpen] = React.useState(false)
  const close = React.useCallback(() => setOpen(false), [])
  if (failed) return <p><span className="wb-doc-imgfail">[image: {alt}]</span></p>
  return (
    <figure className="wb-doc-figure">
      {url ? (
        <button type="button" className="wb-doc-zoom" onClick={() => setOpen(true)} aria-label={`Enlarge image: ${alt}`}>
          <img src={url} alt={alt} loading="lazy" />
        </button>
      ) : (
        <span className="wb-doc-imgwait" role="img" aria-label={`Loading image: ${alt}`} />
      )}
      {caption && <figcaption>{caption}</figcaption>}
      {open && url && <Lightbox url={url} alt={alt} caption={caption} onClose={close} />}
    </figure>
  )
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
          case 'del':
            return <del key={i}><Inlines from={from} c={n.c} /></del>
          case 'img':
            return <DocImage key={i} from={from} src={n.src} alt={n.alt} />
          case 'link': {
            const r = resolveDocLink(from, n.href)
            return r.kind === 'doc' ? (
              <a key={i} href={docHash(r.path, r.slug)}><Inlines from={from} c={n.c} /></a>
            ) : (
              <a key={i} href={r.href} target="_blank" rel="noopener noreferrer" className="wb-doc-ext">
                <Inlines from={from} c={n.c} />
              </a>
            )
          }
        }
      })}
    </>
  )
}

function CodeBlock({ lang, value }: { lang: string; value: string }) {
  const [copied, setCopied] = React.useState(false)
  const timer = React.useRef<number | null>(null)
  React.useEffect(() => () => {
    if (timer.current) window.clearTimeout(timer.current)
  }, [])
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value)
    } catch {
      const ta = document.createElement('textarea')
      ta.value = value
      ta.style.position = 'fixed'
      ta.style.opacity = '0'
      document.body.appendChild(ta)
      ta.select()
      try {
        document.execCommand('copy')
      } catch {
        /* nothing else to try */
      }
      ta.remove()
    }
    setCopied(true)
    if (timer.current) window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => setCopied(false), 1500)
  }
  return (
    <div className="wb-codeblock">
      <div className="wb-codeblock-bar">
        <span className="wb-codeblock-lang">{lang || 'text'}</span>
        <button type="button" className="wb-codeblock-copy" onClick={copy} aria-label={copied ? 'Copied' : `Copy ${lang || 'code'} to the clipboard`}>
          <DocIcon name={copied ? 'check' : 'copy'} size={14} />
          <span aria-live="polite">{copied ? 'Copied' : 'Copy'}</span>
        </button>
      </div>
      <pre tabIndex={0}><code>{value}</code></pre>
    </div>
  )
}

const CALLOUT: Record<CalloutKind, { label: string; icon: string }> = {
  note: { label: 'Note', icon: 'info' },
  tip: { label: 'Tip', icon: 'tip' },
  warning: { label: 'Warning', icon: 'warning' },
  important: { label: 'Important', icon: 'important' },
}

function Blocks({ from, blocks }: { from: string; blocks: Block[] }) {
  return (
    <>
      {blocks.map((b, i) => {
        switch (b.t) {
          case 'h': {
            const Tag = `h${Math.min(b.level, 6)}` as 'h2'
            return (
              <Tag key={i} id={`doc-${b.id}`}>
                <Inlines from={from} c={b.c} />
                {b.level > 1 && (
                  <a className="wb-doc-anchor" href={docHash(from, b.id)} aria-label="Link to this section">
                    <DocIcon name="link" size={14} />
                  </a>
                )}
              </Tag>
            )
          }
          case 'p':
            return <p key={i}><Inlines from={from} c={b.c} /></p>
          case 'quote':
            return <blockquote key={i}><Blocks from={from} blocks={b.c} /></blockquote>
          case 'callout': {
            const k = CALLOUT[b.kind]
            return (
              <aside key={i} className={`wb-callout wb-callout-${b.kind}`} role="note" aria-label={k.label}>
                <span className="wb-callout-icon"><DocIcon name={k.icon} size={18} /></span>
                <div className="wb-callout-body">
                  <strong className="wb-callout-label">{k.label}</strong>
                  <Blocks from={from} blocks={b.c} />
                </div>
              </aside>
            )
          }
          case 'code':
            return <CodeBlock key={i} lang={b.lang} value={b.v} />
          case 'figure':
            return <Figure key={i} from={from} src={b.src} alt={b.alt} caption={b.caption} />
          case 'hr':
            return <hr key={i} />
          case 'list': {
            const L = b.ordered ? 'ol' : 'ul'
            const hasTask = b.items.some((it) => it.task)
            return (
              <L key={i} {...(b.ordered && b.start !== 1 ? { start: b.start } : {})} className={hasTask ? 'wb-tasklist' : undefined}>
                {b.items.map((it, j) => (
                  <li key={j} className={it.task ? 'wb-task' : undefined}>
                    {it.task && (
                      <input type="checkbox" checked={it.task === 'done'} disabled aria-label={it.task === 'done' ? 'Done' : 'Not done'} />
                    )}
                    <div><Blocks from={from} blocks={it.c} /></div>
                  </li>
                ))}
              </L>
            )
          }
          case 'table':
            return (
              <div className="wb-table-wrap" key={i} role="region" aria-label="Table" tabIndex={0}>
                <table className="wb-table">
                  <thead>
                    <tr>
                      {b.head.map((h, j) => (
                        <th key={j} style={b.align[j] ? { textAlign: b.align[j]! } : undefined}><Inlines from={from} c={h} /></th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {b.rows.map((r, j) => (
                      <tr key={j}>
                        {r.map((c, k) => (
                          <td key={k} style={b.align[k] ? { textAlign: b.align[k]! } : undefined}><Inlines from={from} c={c} /></td>
                        ))}
                      </tr>
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
export function Markdown({ from, text, blocks }: { from: string; text?: string; blocks?: Block[] }) {
  const parsed = React.useMemo(() => blocks ?? parseMarkdown(text ?? ''), [blocks, text])
  return (
    <div className="wb-doc">
      <Blocks from={from} blocks={parsed} />
    </div>
  )
}
