// Seeds a throwaway OpenFamily server with a made-up family for screenshots.
// Usage: node seed.mjs <base-url> <admin-email> <admin-password>
// Everything here is fiction: "The Rivera Family", example.com addresses and
// positions in a public square. Never run this against a real server.
const [base, adminEmail, adminPass] = process.argv.slice(2)
const PASS = 'demo-password-123'

async function call(method, path, token, body, headers = {}) {
  const res = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text}`)
  return text ? JSON.parse(text) : {}
}
const login = (email, password, ver = {}) => call('POST', '/auth/login', null, { email, password }, ver)

const admin = (await login(adminEmail, adminPass)).access_token
// The configured platform admin may already sit in an auto-created family: rename
// it. Otherwise create the family. Leftovers from an earlier run are removed.
const me = await call('GET', '/me', admin)
const fams = await call('GET', '/api/admin/families', admin)
const list = Array.isArray(fams) ? fams : (fams.families ?? [])
for (const f of list) if (f.name === 'The Rivera Family' && f.id !== me.family_id) await call('DELETE', `/api/admin/families/${f.id}`, admin).catch(() => {})
let fam
if (me.family_id) {
  await call('PATCH', `/api/admin/families/${me.family_id}`, admin, { name: 'The Rivera Family' })
  fam = { id: me.family_id, name: 'The Rivera Family' }
} else {
  fam = await call('POST', '/api/admin/families', admin, { name: 'The Rivera Family' })
  await call('PATCH', `/api/admin/users/${me.id}/family`, admin, { family_id: fam.id })
}
const people = [
  { name: 'Carlos Rivera', email: 'carlos@example.com', ver: '0.22.1', plat: 'android', lat: 38.7110, lon: -9.1395, battery: 64, role: 'member' },
  { name: 'Sofia Rivera', email: 'sofia@example.com', ver: '0.17.2', plat: 'ios', lat: 38.7139, lon: -9.1334, battery: 91, role: 'member' },
  { name: 'Mateo Rivera', email: 'mateo@example.com', ver: '0.20.0', plat: 'android', lat: 38.7087, lon: -9.1368, battery: 47, role: 'member' },
]
const all = [{ name: 'Maria Rivera', email: adminEmail, pass: adminPass, ver: '0.22.1', plat: 'android', lat: 38.7125, lon: -9.1402, battery: 82 }]
for (const p of people) {
  await call('POST', '/api/admin/users', admin, { email: p.email, password: PASS, name: p.name, role: p.role, family_id: fam.id })
  all.push({ ...p, pass: PASS })
}
for (const p of all) {
  const tok = (await login(p.email, p.pass, { 'X-App-Version': p.ver, 'X-App-Platform': p.plat })).access_token
  const h = { 'X-App-Version': p.ver, 'X-App-Platform': p.plat }
  await call('PATCH', '/me', tok, { name: p.name }, h).catch(() => {})
  const dev = await call('POST', '/devices', tok, { platform: p.plat, name: `${p.name.split(' ')[0]}'s phone`, app_version: p.ver }, h)
  await call('POST', '/locations', tok, { device_id: dev.id ?? dev.device_id, lat: p.lat, lon: p.lon, accuracy_meters: 8, battery_pct: p.battery, speed_mps: 0 }, h)
  await call('GET', '/me', tok, null, h) // records the app version
}
console.log('seeded', all.length, 'people in', fam.name)
