// k6 load test: location ingestion + live WebSocket. NON-PRODUCTION targets only.
// Env: BASE_URL, TOKEN (access token of a test user), DEVICE_ID (that user's device id)
// Note: the API throttles ingestion to 300 points/min per USER, so one token
// can sustain ~5 req/s; use TOKENS (comma separated, with DEVICE_IDS) for more.
import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const base = __ENV.BASE_URL;
const tokens = (__ENV.TOKENS || __ENV.TOKEN || '').split(',').filter(Boolean);
const devices = (__ENV.DEVICE_IDS || __ENV.DEVICE_ID || '').split(',').filter(Boolean);
if (!base || tokens.length === 0 || tokens.length !== devices.length) {
  throw new Error('set BASE_URL and matching TOKEN/DEVICE_ID (or TOKENS/DEVICE_IDS)');
}
const wsOK = new Rate('ws_upgrade_ok');

export const options = {
  scenarios: {
    ingest: { executor: 'constant-vus', vus: Number(__ENV.VUS || 10), duration: __ENV.DURATION || '1m', exec: 'ingest' },
    stream: { executor: 'constant-vus', vus: Number(__ENV.WS_VUS || 10), duration: __ENV.DURATION || '1m', exec: 'stream' },
  },
  thresholds: {
    'http_req_duration{name:ingest}': ['p(95)<500'],
    'http_req_failed{name:ingest}': ['rate<0.01'],
    ws_upgrade_ok: ['rate>0.99'],
  },
};

export function ingest() {
  const i = (__VU - 1) % tokens.length;
  const t = Date.now() / 1000;
  const body = JSON.stringify({
    device_id: devices[i],
    lat: 40.0 + Math.sin(t / 60) * 0.01,
    lon: -74.0 + Math.cos(t / 60) * 0.01,
    accuracy_meters: 8, speed_mps: 3, battery_pct: 80, source: 'loadtest',
  });
  const res = http.post(`${base}/api/locations`, body, {
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${tokens[i]}` },
    tags: { name: 'ingest' },
  });
  check(res, { 'ingest 2xx': (r) => r.status >= 200 && r.status < 300 });
  sleep(Number(__ENV.INTERVAL || 5)); // one fix per VU every INTERVAL s
}

export function stream() {
  const i = (__VU - 1) % tokens.length;
  const url = base.replace(/^http/, 'ws') + '/ws/stream';
  const res = ws.connect(url, { headers: { Authorization: `Bearer ${tokens[i]}` } }, (socket) => {
    socket.on('open', () => socket.setTimeout(() => socket.close(), 20000));
  });
  wsOK.add(res && res.status === 101);
  sleep(1);
}
