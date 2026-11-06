// Render tests for the shared admin layout patterns. The TSX is bundled with
// rolldown (already a build dependency) into a temp file, then server-rendered.
import { test, before } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { rolldown } from 'rolldown'
import React from 'react'
import { renderToStaticMarkup as html } from 'react-dom/server'

let P
before(async () => {
  // Inside the project so the bundle resolves react from node_modules.
  const base = fileURLToPath(new URL('../node_modules/.cache/', import.meta.url))
  mkdirSync(base, { recursive: true })
  const dir = mkdtempSync(join(base, 'wb-patterns-'))
  const bundle = await rolldown({
    input: fileURLToPath(new URL('../src/components/patterns.tsx', import.meta.url)),
    external: ['react', 'react/jsx-runtime'],
    plugins: [
      {
        name: 'stub-css',
        resolveId: (id) => (id.endsWith('.css') ? '\0css' : null),
        load: (id) => (id === '\0css' ? 'export default ""' : null),
      },
    ],
  })
  await bundle.write({ file: join(dir, 'patterns.mjs'), format: 'esm' })
  P = await import(pathToFileURL(join(dir, 'patterns.mjs')).href)
})

const h = React.createElement

test('PageHeader renders title, id, subtitle and actions', () => {
  const out = html(h(P.PageHeader, { title: 'Users', titleId: 'u-h', subtitle: 'Sub', actions: h('button', null, 'Go') }))
  assert.match(out, /<h1 id="u-h" class="wb-page-title">Users<\/h1>/)
  assert.match(out, /wb-page-subtitle">Sub</)
  assert.match(out, /wb-page-actions"><button>Go/)
})

test('PageHeader omits empty subtitle and actions', () => {
  const out = html(h(P.PageHeader, { title: 'T' }))
  assert.ok(!out.includes('wb-page-subtitle'))
  assert.ok(!out.includes('wb-page-actions'))
})

test('Section labels its region with its heading', () => {
  const out = html(h(P.Section, { title: 'Keys', description: 'd' }, h('p', null, 'body')))
  const id = /aria-labelledby="([^"]+)"/.exec(out)[1]
  assert.ok(out.includes(`<h2 id="${id}" class="wb-section-title">Keys</h2>`))
  assert.match(out, /wb-section-desc">d</)
  assert.match(out, /<p>body<\/p>/)
})

test('Alert: danger and warning are role=alert, info is status; title and action render', () => {
  assert.match(html(h(P.Alert, { tone: 'danger', title: 'Bad' }, 'msg')), /role="alert"[^>]*>|wb-alert-danger/)
  const w = html(h(P.Alert, { tone: 'warning' }, 'x'))
  assert.match(w, /role="alert"/)
  const i = html(h(P.Alert, { tone: 'info', title: 'T', action: h('a', null, 'A') }, 'x'))
  assert.match(i, /role="status"/)
  assert.match(i, /wb-alert-title">T</)
  assert.match(i, /wb-alert-action"><a>A/)
  assert.match(i, /aria-hidden="true"/)
})

test('CopyCommand shows the command and an accessible copy button', () => {
  const out = html(h(P.CopyCommand, { command: './scripts/backup.sh' }))
  assert.match(out, /<code class="wb-copycmd-text">\.\/scripts\/backup\.sh<\/code>/)
  assert.match(out, /aria-label="Copy command \.\/scripts\/backup\.sh"/)
  assert.match(out, /type="button"/)
  assert.match(out, />Copy<\/button>/)
})

test('KeyValueList renders one row per item with mono only where asked', () => {
  const out = html(h(P.KeyValueList, { label: 'Server', items: [
    { label: 'Version', value: 'v1', mono: true },
    { label: 'Backup', value: 'ok' },
  ] }))
  assert.match(out, /<dl class="wb-kv" aria-label="Server">/)
  assert.equal((out.match(/wb-kv-row/g) || []).length, 2)
  assert.match(out, /<dd class="wb-kv-value wb-kv-mono">v1<\/dd>/)
  assert.match(out, /<dd class="wb-kv-value">ok<\/dd>/)
})
