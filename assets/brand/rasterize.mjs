// Renders SVG files to PNG with one headless Chromium (no fonts or native libs needed).
//   node assets/brand/rasterize.mjs jobs.json
// jobs.json: [{"svg": "path.svg", "out": "path.png", "w": 512, "h": 512, "bg": "#1C1E22"|null, "pad": 0}]
// Needs Node 22+ and a Chromium/Chrome binary (CHROME=/path, default google-chrome).
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const jobs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const chromeBin = process.env.CHROME || 'google-chrome'
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbitly-raster-'))
const chrome = spawn(chromeBin, ['--headless=new', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
  '--remote-debugging-port=0', `--user-data-dir=${dir}`, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] })
const wsUrl = await new Promise((resolve, reject) => {
  let buf = ''
  chrome.stderr.on('data', (d) => {
    buf += d
    const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf)
    if (m) resolve(m[1])
  })
  setTimeout(() => reject(new Error('chrome did not start')), 120000)
})
const ws = new WebSocket(wsUrl)
await new Promise((r) => (ws.onopen = r))
let id = 0
const pending = new Map()
const events = []
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } else events.push(m)
}
const send = (method, params = {}, sessionId) =>
  new Promise((resolve, reject) => {
    const i = ++id
    pending.set(i, (m) => (m.error ? reject(new Error(method + ': ' + m.error.message)) : resolve(m.result)))
    ws.send(JSON.stringify({ id: i, method, params, sessionId }))
  })

const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
const S = (m, p) => send(m, p, sessionId)
await S('Page.enable')
for (const j of jobs) {
  const svg = fs.readFileSync(j.svg, 'utf8')
  const pad = j.pad || 0
  const inner = j.w - 2 * pad, innerH = j.h - 2 * pad
  const html = `<!doctype html><html><body style="margin:0;background:${j.bg || 'transparent'}">` +
    `<div style="width:${j.w}px;height:${j.h}px;display:flex;align-items:center;justify-content:center">` +
    `<img style="width:${inner}px;height:${innerH}px;display:block" src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}"></div></body></html>`
  await S('Emulation.setDeviceMetricsOverride', { width: j.w, height: j.h, deviceScaleFactor: 1, mobile: false })
  await S('Emulation.setDefaultBackgroundColorOverride', { color: j.bg ? { r: 0, g: 0, b: 0, a: 1 } : { r: 0, g: 0, b: 0, a: 0 } })
  await S('Page.navigate', { url: 'data:text/html;base64,' + Buffer.from(html).toString('base64') })
  await new Promise((r) => setTimeout(r, 400))
  const shot = await S('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: j.w, height: j.h, scale: 1 }, fromSurface: true, captureBeyondViewport: false })
  fs.mkdirSync(path.dirname(j.out), { recursive: true })
  fs.writeFileSync(j.out, Buffer.from(shot.data, 'base64'))
  console.log('wrote', j.out, j.w + 'x' + j.h)
}
ws.close()
chrome.kill('SIGKILL')
try { fs.rmSync(dir, { recursive: true, force: true, maxRetries: 3 }) } catch {}
process.exit(0)
