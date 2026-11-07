// Builds every raster and copies the SVGs to where the products load them.
//   python3 assets/brand/generate.py && node assets/brand/build-rasters.mjs
// Needs Node 22+ and a Chromium (see rasterize.mjs). No other tools.
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../..')
const B = (f) => path.join(HERE, f)
const jobs = []
const opaque = new Set()      // PNGs that must have no alpha channel
const job = (svg, out, w, h = w, bg = null, noAlpha = false) => {
  out = path.join(ROOT, out)
  jobs.push({ svg: B(svg), out, w, h, bg })
  if (noAlpha) opaque.add(out)
}
const copy = (from, to) => { to = path.join(ROOT, to); fs.mkdirSync(path.dirname(to), { recursive: true }); fs.copyFileSync(B(from), to) }

// --- brand folder
job('orbitly-app-icon.svg', 'assets/brand/orbitly-app-icon.png', 1024, 1024, null, true)
job('orbitly-mark.svg', 'assets/brand/orbitly-mark.png', 512)
job('orbitly-mark-dark.svg', 'assets/brand/orbitly-mark-dark.png', 512)
job('orbitly-social-card.svg', 'assets/brand/orbitly-social-card.png', 1280, 640)
job('orbitly-banner.svg', 'assets/brand/orbitly-banner.png', 1280, 320)

// --- Android legacy launcher icons (adaptive + monochrome are vector XML from generate.py)
const dens = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 }
for (const [d, px] of Object.entries(dens)) job('orbitly-icon-tile.svg', `app/android/app/src/main/res/mipmap-${d}/ic_launcher.png`, px)

// --- iOS app icons (opaque) and launch image
const ios = 'app/ios/Runner/Assets.xcassets/AppIcon.appiconset/'
const sizes = { '20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60, '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87, '40x40@1x': 40, '40x40@2x': 80,
  '40x40@3x': 120, '60x60@2x': 120, '60x60@3x': 180, '76x76@1x': 76, '76x76@2x': 152, '83.5x83.5@2x': 167, '1024x1024@1x': 1024 }
for (const [n, px] of Object.entries(sizes)) job('orbitly-app-icon.svg', `${ios}Icon-App-${n}.png`, px, px, null, true)
const li = 'app/ios/Runner/Assets.xcassets/LaunchImage.imageset/'
for (const [suffix, k] of [['', 1], ['@2x', 2], ['@3x', 3]]) {
  job('orbitly-mark.svg', `${li}LaunchImage${suffix}.png`, 168 * k, 185 * k)
  job('orbitly-mark-dark.svg', `${li}LaunchImage-dark${suffix}.png`, 168 * k, 185 * k)
}

// --- Flutter in-app logo assets
const br = 'app/assets/branding/'
job('orbitly-mark.svg', br + 'orbitly-icon.png', 256)
job('orbitly-mark-dark.svg', br + 'orbitly-icon-dark.png', 256)
job('orbitly-logo-horizontal.svg', br + 'orbitly-logo-horizontal.png', 1200, 400)
job('orbitly-logo-horizontal-dark.svg', br + 'orbitly-logo-horizontal-dark.png', 1200, 400)
job('orbitly-logo-vertical.svg', br + 'orbitly-logo-vertical.png', 600)
job('orbitly-logo-vertical-dark.svg', br + 'orbitly-logo-vertical-dark.png', 600)

// --- admin web (public/brand + favicons + PWA)
const wp = 'web/public/'
job('orbitly-social-card.svg', wp + 'brand/orbitly-social-card.png', 1280, 640)
job('orbitly-app-icon.svg', wp + 'brand/orbitly-touch-icon.png', 180, 180, null, true)
job('orbitly-icon-tile.svg', wp + 'icon-192.png', 192)
job('orbitly-icon-tile.svg', wp + 'icon-512.png', 512)
job('orbitly-app-icon.svg', wp + 'icon-maskable-512.png', 512, 512, null, true)
for (const px of [16, 32, 48]) job('favicon.svg', `assets/brand/.favicon-${px}.png`, px)

// --- marketing site
job('orbitly-app-icon.svg', 'site/assets/brand/orbitly-app-icon.png', 512, 512, null, true)
job('orbitly-social-card.svg', 'site/assets/brand/orbitly-social-card.png', 1280, 640)
// --- Play Store icon
job('orbitly-app-icon.svg', 'assets/google-play/upload/icon-512.png', 512, 512, null, true)

const jf = path.join(HERE, '.jobs.json')
fs.writeFileSync(jf, JSON.stringify(jobs))
const r = spawnSync('node', [B('rasterize.mjs'), jf], { stdio: 'inherit' })
fs.rmSync(jf, { force: true })
if (r.status !== 0) process.exit(r.status || 1)

// --- strip alpha (iOS marketing icon must not have one)
function readPng(buf) {
  let pos = 8, w = 0, h = 0, idat = []
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString('ascii', pos + 4, pos + 8)
    if (type === 'IHDR') { w = buf.readUInt32BE(pos + 8); h = buf.readUInt32BE(pos + 12) }
    if (type === 'IDAT') idat.push(buf.subarray(pos + 8, pos + 8 + len))
    pos += 12 + len
  }
  const raw = zlib.inflateSync(Buffer.concat(idat)), bpp = 4, stride = w * bpp
  const out = Buffer.alloc(h * stride)
  for (let y = 0; y < h; y++) {
    const ft = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1))
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[y * stride + x - bpp] : 0, b = y ? out[(y - 1) * stride + x] : 0, c = x >= bpp && y ? out[(y - 1) * stride + x - bpp] : 0
      let v = line[x]
      if (ft === 1) v += a; else if (ft === 2) v += b; else if (ft === 3) v += (a + b) >> 1
      else if (ft === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c }
      out[y * stride + x] = v & 255
    }
  }
  return { w, h, rgba: out }
}
const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 })
const crc32 = (b) => { let c = 0xffffffff; for (const x of b) c = crcTable[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0 }
function chunk(type, data) {
  const t = Buffer.from(type), len = Buffer.alloc(4), crc = Buffer.alloc(4)
  len.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(Buffer.concat([t, data])))
  return Buffer.concat([len, t, data, crc])
}
function writeRgb(file, { w, h, rgba }) {
  const rows = Buffer.alloc(h * (w * 3 + 1))
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let k = 0; k < 3; k++) rows[y * (w * 3 + 1) + 1 + x * 3 + k] = rgba[(y * w + x) * 4 + k]
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2
  fs.writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(rows, { level: 9 })), chunk('IEND', Buffer.alloc(0))]))
}
for (const f of opaque) {
  const buf = fs.readFileSync(f)
  if (buf[25] === 2) continue            // already RGB (Chromium omits alpha for fully opaque images)
  writeRgb(f, readPng(buf))
}

// --- favicon.ico (PNG-compressed entries) and SVG/web copies
const icoPngs = [16, 32, 48].map((px) => fs.readFileSync(path.join(ROOT, `assets/brand/.favicon-${px}.png`)))
const head = Buffer.alloc(6); head.writeUInt16LE(1, 2); head.writeUInt16LE(icoPngs.length, 4)
let off = 6 + 16 * icoPngs.length
const dirs = icoPngs.map((p, i) => { const e = Buffer.alloc(16); const px = [16, 32, 48][i]; e[0] = px; e[1] = px; e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6); e.writeUInt32LE(p.length, 8); e.writeUInt32LE(off, 12); off += p.length; return e })
fs.writeFileSync(path.join(ROOT, wp + 'favicon.ico'), Buffer.concat([head, ...dirs, ...icoPngs]))
for (const px of [16, 32, 48]) fs.rmSync(path.join(ROOT, `assets/brand/.favicon-${px}.png`))
for (const [from, to] of [['favicon.svg', wp + 'favicon.svg'], ['orbitly-mark.svg', wp + 'brand/orbitly-icon.svg'],
  ['orbitly-mark-dark.svg', wp + 'brand/orbitly-icon-dark.svg'], ['orbitly-mark-on-accent.svg', wp + 'brand/orbitly-icon-on-accent.svg'],
  ['orbitly-logo-horizontal.svg', wp + 'brand/orbitly-logo-horizontal.svg'], ['orbitly-logo-horizontal-dark.svg', wp + 'brand/orbitly-logo-horizontal-dark.svg'],
  ['favicon.svg', 'site/assets/brand/favicon.svg'],
  ['orbitly-mark.svg', 'site/assets/brand/orbitly-icon.svg'], ['orbitly-mark-dark.svg', 'site/assets/brand/orbitly-icon-dark.svg'],
  ['orbitly-mark-on-accent.svg', 'site/assets/brand/orbitly-icon-on-accent.svg'],
  ['orbitly-logo-horizontal.svg', 'site/assets/brand/orbitly-logo-horizontal.svg'], ['orbitly-logo-horizontal-dark.svg', 'site/assets/brand/orbitly-logo-horizontal-dark.svg']]) copy(from, to)
console.log('brand build done')
