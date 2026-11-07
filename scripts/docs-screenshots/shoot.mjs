// Captures the admin web pages for the docs. Usage: node shoot.mjs <base-url> <email> <password> <out-dir>
import { chromium } from 'playwright'
import fs from 'node:fs'

const [base, email, password, out] = process.argv.slice(2)
fs.mkdirSync(out, { recursive: true })
const pages = [
  ['dashboard', '#/dashboard'],
  ['families', '#/families'],
  ['documents', '#/documents'],
  ['document-page', '#/documents/user/privacy-modes.md'],
  ['app-versions', '#/settings', 'App versions'],
  ['system', '#/system'],
  ['fleet', '#/fleet'],
]
const modes = [
  { name: 'light', scheme: 'light', width: 1280, height: 800, suffix: '' },
  { name: 'dark', scheme: 'dark', width: 1280, height: 800, suffix: '-dark' },
  { name: 'mobile', scheme: 'light', width: 390, height: 844, suffix: '-mobile', mobile: true },
]
const browser = await chromium.launch()
for (const m of modes) {
  const ctx = await browser.newContext({
    viewport: { width: m.width, height: m.height },
    colorScheme: m.scheme,
    deviceScaleFactor: m.mobile ? 2 : 1,
    isMobile: !!m.mobile,
  })
  const page = await ctx.newPage()
  await page.goto(`${base}/admin/`)
  await page.getByLabel(/email/i).first().fill(email)
  await page.getByLabel(/password/i).first().fill(password)
  await page.getByRole('button', { name: /sign in|log in/i }).first().click()
  await page.waitForSelector('.wb-shell', { timeout: 30000 })
  await page.reload() // a fresh load picks up the signed-in identity reliably
  await page.waitForSelector('.wb-shell', { timeout: 30000 })
  for (const [name, hash, scrollTo] of pages) {
    // Navigate by hash (no reload), then wait until the page has finished loading.
    await page.evaluate((h) => { window.location.hash = h }, hash)
    await page.waitForTimeout(300)
    await page.waitForFunction(() => !document.querySelector('.wb-page-loading, .wb-spinner'), null, { timeout: 30000 }).catch(() => {})
    if (name.startsWith('document')) await page.waitForSelector('.wb-docs-layout', { timeout: 30000 })
    if (name === 'document-page') await page.waitForSelector('.wb-doc img', { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(name === 'dashboard' ? 5000 : 2000)
    if (scrollTo) {
      const el = page.getByRole('heading', { name: scrollTo }).first()
      await el.scrollIntoViewIfNeeded().catch(() => {})
      await page.waitForTimeout(500)
    }
    // Light is the reference; dark/mobile only for the pages where it matters.
    if (m.name !== 'light' && !['dashboard', 'documents', 'app-versions'].includes(name)) continue
    const file = `${out}/${name}${m.suffix === '' ? '-light' : m.suffix}.png`
    if (scrollTo) {
      // A settings card: capture just that card, whole.
      await page.setViewportSize({ width: m.width, height: 2600 })
      await page.waitForTimeout(800)
      const card = page.locator('div.wb-card', { has: page.getByRole('heading', { name: scrollTo }) }).last()
      await card.screenshot({ path: file })
      await page.setViewportSize({ width: m.width, height: m.height })
    } else {
      await page.screenshot({ path: file })
    }
  }
  await ctx.close()
}
await browser.close()
