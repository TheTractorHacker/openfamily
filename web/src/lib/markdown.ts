// A small, dependency-free Markdown parser for the built-in documentation.
// It produces a plain tree (never HTML strings), so rendering with React cannot
// inject markup: raw HTML in a document is shown as text. Supported: headings,
// paragraphs, bullet/numbered lists (nested by indent), block quotes, fenced
// code, tables, rules, and inline code, bold, italic, links and images.

export type Inline =
  | { t: 'text'; v: string }
  | { t: 'code'; v: string }
  | { t: 'strong'; c: Inline[] }
  | { t: 'em'; c: Inline[] }
  | { t: 'link'; href: string; c: Inline[] }
  | { t: 'img'; src: string; alt: string }

export type Block =
  | { t: 'h'; level: number; id: string; c: Inline[] }
  | { t: 'p'; c: Inline[] }
  | { t: 'quote'; c: Block[] }
  | { t: 'code'; lang: string; v: string }
  | { t: 'list'; ordered: boolean; items: Block[][] }
  | { t: 'table'; head: Inline[][]; rows: Inline[][][] }
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

const INLINE = /(`+)([\s\S]*?[^`])\1(?!`)|!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|\*\*([\s\S]+?)\*\*|(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])|(?<![\w_])_([^_\s][^_]*?)_(?![\w_])/g

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
    else if (m[4] !== undefined) out.push({ t: 'img', alt: m[3], src: m[4] })
    else if (m[6] !== undefined) {
      const href = safeHref(m[6])
      if (href === null) push(m[5])
      else out.push({ t: 'link', href, c: parseInline(m[5]) })
    } else if (m[7] !== undefined) out.push({ t: 'strong', c: parseInline(m[7]) })
    else out.push({ t: 'em', c: parseInline((m[8] ?? m[9]) as string) })
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

export function parseMarkdown(src: string): Block[] {
  const lines = src.replace(/\r\n?/g, '\n').split('\n')
  const used = new Map<string, number>()
  return parseBlocks(lines, used)
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
      out.push({ t: 'quote', c: parseBlocks(buf, used) })
      continue
    }
    if (line.includes('|') && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
      const head = splitRow(line).map(parseInline)
      i += 2
      const rows: Inline[][][] = []
      while (i < lines.length && lines[i].includes('|') && lines[i].trim()) rows.push(splitRow(lines[i++]).map(parseInline))
      out.push({ t: 'table', head, rows })
      continue
    }
    const lm = listMark(line)
    if (lm) {
      const base = lm[1].length
      const ordered = /\d/.test(lm[2])
      const items: Block[][] = []
      while (i < lines.length) {
        const m = listMark(lines[i])
        if (!m || m[1].length !== base) break
        const body: string[] = [m[3]]
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
        items.push(parseBlocks(body, used))
      }
      out.push({ t: 'list', ordered, items })
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
    out.push({ t: 'p', c: parseInline(buf.join(' ')) })
  }
  return out
}

export function headingsOf(blocks: Block[]): { level: number; id: string; text: string }[] {
  return blocks.flatMap((b) => (b.t === 'h' ? [{ level: b.level, id: b.id, text: plainOf(b.c) }] : []))
}
