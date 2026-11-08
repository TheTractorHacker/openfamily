// A small, dependency-free Markdown parser for the built-in documentation.
// It produces a plain tree (never HTML strings), so rendering with React cannot
// inject markup: raw HTML in a document is shown as text. Supported: headings,
// paragraphs, bullet/numbered lists (nested by indent, task lists), block quotes,
// callouts (a quote starting with **Note**, **Tip**, **Warning**, **Important**
// or GitHub's [!NOTE]), fenced code, tables (with column alignment), rules,
// figures (an image alone in its paragraph) and inline code, bold, italic,
// strikethrough, links and images.

export type Inline =
  | { t: 'text'; v: string }
  | { t: 'code'; v: string }
  | { t: 'strong'; c: Inline[] }
  | { t: 'em'; c: Inline[] }
  | { t: 'link'; href: string; c: Inline[] }
  | { t: 'del'; c: Inline[] }
  | { t: 'img'; src: string; alt: string; title?: string }

export type CalloutKind = 'note' | 'tip' | 'warning' | 'important'
export type Align = 'left' | 'center' | 'right' | null
export interface ListItem {
  c: Block[]
  /** Set for task-list items ("- [ ] x" / "- [x] x"). */
  task?: 'open' | 'done'
}

export type Block =
  | { t: 'h'; level: number; id: string; c: Inline[] }
  | { t: 'p'; c: Inline[] }
  | { t: 'quote'; c: Block[] }
  | { t: 'code'; lang: string; v: string }
  | { t: 'callout'; kind: CalloutKind; c: Block[] }
  | { t: 'figure'; src: string; alt: string; caption: string }
  | { t: 'list'; ordered: boolean; start: number; items: ListItem[] }
  | { t: 'table'; head: Inline[][]; rows: Inline[][][]; align: Align[] }
  | { t: 'hr' }

/** GitHub-style heading slug. Keep in step with scripts/docs-lib.mjs. */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/`/g, '')
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .trim()
    .replace(/\s/g, '-')
}

export function plainOf(c: Inline[]): string {
  return c
    .map((i) => {
      switch (i.t) {
        case 'text':
        case 'code':
          return i.v
        case 'img':
          return i.alt
        default:
          return plainOf(i.c)
      }
    })
    .join('')
}

/** Only these URL schemes survive; anything else (javascript:, data:) is dropped. */
export function safeHref(href: string): string | null {
  const h = href.trim()
  if (/^[a-z][a-z0-9+.-]*:/i.test(h)) return /^(https?:|mailto:)/i.test(h) ? h : null
  return h
}

const INLINE = /(`+)([\s\S]*?[^`])\1(?!`)|!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)|\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|\*\*([\s\S]+?)\*\*|~~([^~]+?)~~|<(https?:\/\/[^\s<>]+)>|(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])|(?<![\w_])_([^_\s][^_]*?)_(?![\w_])/g

export function parseInline(src: string): Inline[] {
  const out: Inline[] = []
  let last = 0
  const push = (s: string) => {
    if (s) out.push({ t: 'text', v: s.replace(/\\([\\`*_{}[\]()#+\-.!|<>])/g, '$1') })
  }
  for (const m of src.matchAll(INLINE)) {
    push(src.slice(last, m.index))
    last = (m.index ?? 0) + m[0].length
    if (m[2] !== undefined) out.push({ t: 'code', v: m[2].trim() })
    else if (m[4] !== undefined) out.push({ t: 'img', alt: m[3], src: m[4], title: m[5] || undefined })
    else if (m[7] !== undefined) {
      const href = safeHref(m[7])
      if (href === null) push(m[6])
      else out.push({ t: 'link', href, c: parseInline(m[6]) })
    } else if (m[8] !== undefined) out.push({ t: 'strong', c: parseInline(m[8]) })
    else if (m[9] !== undefined) out.push({ t: 'del', c: parseInline(m[9]) })
    else if (m[10] !== undefined) out.push({ t: 'link', href: m[10], c: [{ t: 'text', v: m[10] }] })
    else out.push({ t: 'em', c: parseInline((m[11] ?? m[12]) as string) })
  }
  push(src.slice(last))
  return out
}

const isRule = (l: string) => /^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(l)
const listMark = (l: string) => /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(l)
const splitRow = (l: string) =>
  l
    .trim()
    .replace(/^\||\|$/g, '')
    .split(/(?<!\\)\|/)
    .map((c) => c.trim().replace(/\\\|/g, '|'))
const alignOf = (cell: string): Align => {
  const c = cell.trim()
  if (/^:-+:$/.test(c)) return 'center'
  if (/^-+:$/.test(c)) return 'right'
  if (/^:-+$/.test(c)) return 'left'
  return null
}

export function parseMarkdown(src: string): Block[] {
  const lines = src.replace(/\r\n?/g, '\n').split('\n')
  const used = new Map<string, number>()
  return parseBlocks(lines, used)
}

const CALLOUT_WORDS: Record<string, CalloutKind> = {
  note: 'note',
  info: 'note',
  tip: 'tip',
  hint: 'tip',
  warning: 'warning',
  caution: 'warning',
  important: 'important',
}

/** A block quote that opens with a keyword becomes a callout; otherwise null. */
export function asCallout(blocks: Block[]): Block | null {
  const first = blocks[0]
  if (!first || first.t !== 'p' || !first.c.length) return null
  const lead = first.c[0]
  let kind: CalloutKind | undefined
  let rest: Inline[] = []
  if (lead.t === 'strong') {
    kind = CALLOUT_WORDS[plainOf(lead.c).trim().replace(/[:.]$/, '').toLowerCase()]
    rest = first.c.slice(1)
    if (rest[0]?.t === 'text') rest = [{ t: 'text', v: rest[0].v.replace(/^\s*:\s*/, '') }, ...rest.slice(1)]
  } else if (lead.t === 'text') {
    const m = /^\[!(NOTE|TIP|WARNING|IMPORTANT|CAUTION)\]\s*/i.exec(lead.v)
    if (m) {
      kind = CALLOUT_WORDS[m[1].toLowerCase()]
      rest = [{ t: 'text', v: lead.v.slice(m[0].length) }, ...first.c.slice(1)]
    }
  }
  if (!kind) return null
  const tidy = rest.filter((i) => !(i.t === 'text' && !i.v.trim()))
  const body: Block[] = tidy.length ? [{ t: 'p', c: rest }, ...blocks.slice(1)] : blocks.slice(1)
  return { t: 'callout', kind, c: body }
}

function parseBlocks(lines: string[], used: Map<string, number>): Block[] {
  const out: Block[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    if (!line.trim()) {
      i++
      continue
    }
    const fence = /^\s*(```+|~~~+)\s*([\w-]*)/.exec(line)
    if (fence) {
      const buf: string[] = []
      i++
      while (i < lines.length && !lines[i].trim().startsWith(fence[1].slice(0, 3))) buf.push(lines[i++])
      i++
      out.push({ t: 'code', lang: fence[2], v: buf.join('\n') })
      continue
    }
    const h = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line)
    if (h) {
      const c = parseInline(h[2])
      let id = slugify(plainOf(c))
      const n = used.get(id) ?? 0
      used.set(id, n + 1)
      if (n) id = `${id}-${n}`
      out.push({ t: 'h', level: h[1].length, id, c })
      i++
      continue
    }
    if (isRule(line)) {
      out.push({ t: 'hr' })
      i++
      continue
    }
    if (/^\s*>/.test(line)) {
      const buf: string[] = []
      while (i < lines.length && /^\s*>/.test(lines[i])) buf.push(lines[i++].replace(/^\s*> ?/, ''))
      const inner = parseBlocks(buf, used)
      out.push(asCallout(inner) ?? { t: 'quote', c: inner })
      continue
    }
    if (line.includes('|') && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
      const head = splitRow(line).map(parseInline)
      const align = splitRow(lines[i + 1]).map(alignOf)
      i += 2
      const rows: Inline[][][] = []
      while (i < lines.length && lines[i].includes('|') && lines[i].trim()) rows.push(splitRow(lines[i++]).map(parseInline))
      out.push({ t: 'table', head, rows, align })
      continue
    }
    const lm = listMark(line)
    if (lm) {
      const base = lm[1].length
      const ordered = /\d/.test(lm[2])
      const start = ordered ? parseInt(lm[2], 10) : 1
      const items: ListItem[] = []
      while (i < lines.length) {
        const m = listMark(lines[i])
        if (!m || m[1].length !== base) break
        let first = m[3]
        let task: ListItem['task']
        const tm = /^\[([ xX])\]\s+(.*)$/.exec(first)
        if (tm) {
          task = tm[1] === ' ' ? 'open' : 'done'
          first = tm[2]
        }
        const body: string[] = [first]
        i++
        while (i < lines.length) {
          const l = lines[i]
          if (!l.trim()) {
            // a blank line continues the item only if the next line is indented deeper
            if (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1]) && (lines[i + 1].match(/^\s*/)?.[0].length ?? 0) > base) {
              body.push('')
              i++
              continue
            }
            break
          }
          const ind = l.match(/^\s*/)?.[0].length ?? 0
          const nm = listMark(l)
          if (ind > base) {
            body.push(l.slice(Math.min(ind, base + 2)))
            i++
          } else if (!nm && ind === 0 && body.length && !/^(#{1,6}\s|>|```|~~~|\|)/.test(l) && !isRule(l)) {
            body.push(l) // lazy continuation
            i++
          } else break
        }
        items.push({ c: parseBlocks(body, used), ...(task ? { task } : {}) })
      }
      out.push({ t: 'list', ordered, start, items })
      continue
    }
    const buf: string[] = []
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^(#{1,6}\s|\s*>|\s*(```|~~~))/.test(lines[i]) &&
      !isRule(lines[i]) &&
      !(buf.length && listMark(lines[i]))
    ) {
      buf.push(lines[i++].trim())
    }
    if (!buf.length) {
      buf.push(lines[i++])
    }
    const c = parseInline(buf.join(' '))
    const only = c.length === 1 ? c[0] : null
    if (only && only.t === 'img') out.push({ t: 'figure', src: only.src, alt: only.alt, caption: only.title || only.alt })
    else out.push({ t: 'p', c })
  }
  return out
}

export function headingsOf(blocks: Block[]): { level: number; id: string; text: string }[] {
  return blocks.flatMap((b) => (b.t === 'h' ? [{ level: b.level, id: b.id, text: plainOf(b.c) }] : []))
}

/** "On this page": the second and third level headings, in order. */
export function tocOf(blocks: Block[]): { level: 2 | 3; id: string; text: string }[] {
  return headingsOf(blocks).filter((h): h is { level: 2 | 3; id: string; text: string } => h.level === 2 || h.level === 3)
}

/** The page title: the first level-1 heading, or null. */
export function titleOfBlocks(blocks: Block[]): string | null {
  const h = headingsOf(blocks).find((x) => x.level === 1)
  return h ? h.text : null
}
