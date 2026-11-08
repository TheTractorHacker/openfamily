# API wire efficiency

How the app and server keep requests small, few and reliable on mobile networks, and whether to use the HTTP QUERY method.

Goal: a phone keeps a small working set and fetches the rest on demand, cheaply
on mobile networks. Everything below is **additive**: apps 0.20-0.24 send none
of the new parameters and get exactly the responses they always got. A new app
detects the server through `features.wire_v2` (in `GET /compat` and
`GET /app/bootstrap`) and falls back to the old requests on a server without it.

All numbers in this page were **measured on a local test server with seeded data
(one circle, six people, one person with a 24 hour trail), not on a phone and
not through Cloudflare.** Sizes are the JSON body in bytes; "gzip" is the size
after the server's own gzip (level 1).

## 1. What the app calls (before)

| When | Calls | Notes |
|---|---|---|
| Cold start / map open | `GET /family`, `/circles`, `/family/members[?circle_id=]`, `/family/places`, `/chat/unread`, `/config`, then the WebSocket `/ws/stream` | 5-7 sequential-ish round trips, each previously on a **brand new TCP+TLS connection** (see below) |
| Resume | `refreshMembers()` = `GET /family/members` + `GET /family/places` (places cached briefly) | on every resume, even when the WebSocket is healthy; returns the whole list again |
| Open a person's day | `GET /family/members/{id}/history?from&to` | already bucketed to 30 s and capped at 1500 points / 25 h |
| Chat | `GET /circles/{id}/chat?after=` catch-up + WebSocket frames | already incremental |
| Driving / trips | `GET /trips?limit`, `/trips/{id}?max_points=400` | already paged and thinned |
| Background | location uploads (`POST /locations`), heartbeat | unchanged |

Findings:

1. **No connection reuse.** `ApiClient` used the top-level `http.get/post`
   helpers, which create and close an HTTP client per request: every call paid a
   new TCP and TLS handshake (about 2-3 round trips of latency on 4G). Fixed: one
   long-lived client, so keep-alive (and HTTP/2 where the platform stack offers
   it) is used.
2. **Responses were never compressed by the API itself** (Caddy compresses
   when it is in front; a direct or tunnel setup did not). Fixed: gzip in the
   API, and `zstd gzip` in Caddy.
3. **Full lists every time.** Members include email, phone, TOTP state and
   account timestamps the map never shows, and the whole list is re-sent when
   one person moved. Fixed with `view=compact` and `?since=` deltas.
4. **Resume = full refetch** even if nothing changed. Fixed generically with
   ETag/304 (unchanged lists cost a header-only response).
5. **Cold start is 5+ requests.** Fixed with `GET /app/bootstrap`.
6. Polling vs WebSocket: members/chat/alerts arrive over the WebSocket; REST is
   only used for the first snapshot, on resume and for catch-up. There is no
   periodic REST poll while connected (checked: the only periodic timers are the
   30 s WebSocket ping, a 30 s local staleness re-evaluation and the watchdog).
   The WebSocket ping is an app-level 30 s frame (tiny), reconnect backoff is
   1-30 s with jitter-free doubling and resets only after a connection stayed up.
7. `ApiClient` already decodes bodies above 128 KiB on a worker isolate, so no
   change was needed there.

## 2. What was added

| Feature | How a client uses it | Server compat story |
|---|---|---|
| gzip | send `Accept-Encoding: gzip` (dart:io does it automatically and decodes) | only for JSON/text above 512 bytes, never WebSocket/SSE/images |
| ETag / 304 | repeat a GET with `If-None-Match` from the last `ETag` | weak validator over the body for every authenticated JSON GET; ignored by clients that do not send it |
| Compact members | `GET /family/members?view=compact` or `fields=id,name,lat,lon` | default response unchanged |
| Delta | `GET /family/members?since=<cursor>` and `GET /family/places?since=<cursor>` | see below |
| Bootstrap | `GET /app/bootstrap` | 404 on older servers, client falls back |
| History thinning | `GET /family/members/{id}/history?...&simplify=<m>&max_points=<n>` | optional |
| Several windows | `POST` or `QUERY /family/history/query` | new route |
| Audit paging | `GET /audit?limit=&before=` + `X-Next-Cursor` | default is still the newest 100 |

### Delta lists

`?since=<cursor>` (any non-empty value, `none` for the first call) switches the
response to an object:

```json
{"cursor":"1760000000000-ab12cd34ef56","full":false,
 "items":[{"id":"...","lat":51.5}],"ids":["id1","id2"]}
```

* `full:true` means `items` is the whole list: replace local state.
* `full:false` means merge `items` by id and **drop every local row whose id is
  not in `ids`**. A deletion is the absence of the id, so there is no tombstone
  table to grow or expire, and a missed delete can never linger.
* The cursor is the snapshot time plus a short hash of the list's structure
  (who is in it, roles, who shares where). If the structure changed, or the cursor
  is older than 15 minutes, malformed or from the future, the server answers
  `full:true`. Role, membership and sharing changes have no timestamp, which is
  why they go through the hash instead.
* Members changed = updated profile, new position, new heartbeat or avatar.
  Places changed = `places.updated_at` (migration 000360, set by a trigger).
* Authorization is unchanged: the delta is the same list the caller may see,
  filtered. Other circles' people never appear in `items` or `ids`.
* Honest limit: the server still runs the same queries; the saving is bytes on
  the phone's network and JSON decoding, not database work. Chat keeps its own
  `?after=` cursor, and alerts are already paged with `limit`.

### Bootstrap

`GET /app/bootstrap[?view=full]` runs the existing circles, members and unread
handlers as the same caller and returns them with compatibility info, the
server's feature map and a `wire` object (`etag`, `gzip`, `delta`, `query`...).
A section that fails (for example members when you have no circle yet) is `null`
with its status in `errors`. Authorization lives in exactly one place because
the existing handlers are reused.

## 3. The HTTP QUERY method: should we use it?

**What it is.** QUERY is a safe, idempotent request method that carries its
parameters in a request body. It is **RFC 10008, "The HTTP QUERY Method"**
(Proposed Standard, IETF HTTP working group, authors Reschke, Snell, Bishop,
formerly `draft-ietf-httpbis-safe-method-w-body`). Servers advertise support with
an `Accept-Query` header. Sources:
<https://www.rfc-editor.org/rfc/rfc10008.html>,
<https://datatracker.ietf.org/doc/draft-ietf-httpbis-safe-method-w-body/>.

**Benefits for this app.** Reads whose input does not fit a URL well: many
ids, several time windows, structured filters; without abusing POST (which
caches and retries as unsafe).

**Real risks and what we know:**

| Layer | Status |
|---|---|
| Go `net/http` | accepts any method token. Tested. |
| chi router | needs `chi.RegisterMethod("QUERY")` before routing. Done in `main.go`. |
| Caddy reverse proxy | passes unknown methods and bodies. Verified locally (below). |
| Cloudflare (owner's domain) | **not verified.** Cloudflare's WAF/managed rules, Bot Fight Mode or an Access policy may block or rewrite unknown methods. Test command below. |
| Dart `package:http` | works with a raw `Request('QUERY', uri)`. Tested with fakes and, locally, against the real server. |
| OkHttp / Android, iOS URLSession | allow custom methods in principle (`dart:io` HttpClient sends the token as is); not verified on devices. Some carrier proxies and enterprise middleboxes drop unknown methods: this is why a fallback exists. |
| Browsers | QUERY is not CORS-safelisted, so a cross-origin call costs a preflight (`OPTIONS`); the server allows `QUERY` in `Access-Control-Allow-Methods`. The admin web is same-origin and does not use it. |
| Caching | shared caches that understand QUERY key on the body; most do not cache it at all, so there is no caching benefit over GET with ETag here. |
| Logging / WAF | many log pipelines and WAF rules only know GET/POST. |

**Measured benefit here: none that justifies it.** Member and position reads
fit in a short `GET ?circle_id=all&view=compact&since=`; a trail is one GET per
day. The only place a body helps is fetching several time windows of one person
in one round trip, which POST does just as well. So the implementation is
minimal and **off by default**:

* `POST /family/history/query` always works (it is a read).
* `QUERY /family/history/query` works only when the operator sets
  `QUERY_METHOD=1`; otherwise it answers `405` with `Allow: POST`. Both routes
  set `Accept-Query: "application/json"`.
* `ApiClient.query(path, body)` tries QUERY, falls back to POST on 405, 501,
  400, 415 or a dropped connection, and remembers the result per server for 24
  hours (`QueryCapability`, stored in preferences). If the server says QUERY is
  off (`wire.query:false` in bootstrap) it does not probe at all. A genuine
  answer such as 403 is returned as is and never retried as POST.
* Nothing in the app calls `query()` yet; it is there for the first screen that
  needs several windows, so no screen changes were made.

**Test it through Cloudflare on the owner's domain** (replace the token; the
server needs `QUERY_METHOD=1` for a 200, otherwise a `405` from the origin still
proves the method passed Cloudflare, whereas a Cloudflare HTML error page or a
`403`/`400` with `server: cloudflare` and no JSON body means it was blocked):

```
curl -i -X QUERY https://life.foleyit.com/family/history/query \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"member_id":"00000000-0000-0000-0000-000000000000","windows":[]}'
```

Expected from the origin: `HTTP/2 400` with `{"error":"member_id and 1-8 windows are required"}`
(enabled) or `405` with `Allow: POST, OPTIONS` (disabled). Compare with the same
call using `-X POST`.

## 4. Reliability in `ApiClient`

* One shared keep-alive client.
* Timeouts per class: 15 s for reads and normal writes, 60 s for raw-byte uploads.
* Retry only GET (idempotent), up to 2 times, on network errors, timeouts and
  502/503/504, with jittered exponential backoff (about 125-250 ms, then 250-500 ms).
  POST/PATCH/PUT/DELETE are never retried automatically.
* Simultaneous identical GETs share one request (keyed by session and URL).
* `ApiCancelToken`: a disposed screen stops waiting (the response is dropped; a
  request already on the wire cannot be aborted with `package:http`).
* Conditional GET cache: bounded (24 entries, 256 KiB each, 1 MiB total), cleared
  when a session starts or ends; never used for `?since=` URLs.
* Token refresh logic is untouched.

## 5. Caddy, Cloudflare, HTTP/2 and HTTP/3

* Caddy serves HTTP/1.1, HTTP/2 and HTTP/3 on its HTTPS site automatically; keep
  UDP 443 open for HTTP/3. `encode zstd gzip` compresses JSON; the push SSE path
  is excluded. Responses already compressed by the API are left alone.
* Behind a Cloudflare Tunnel or proxy, Cloudflare terminates the client
  connection (HTTP/2 or 3 to the phone) and speaks HTTP/1.1 or 2 to the origin;
  keep-alive to the phone is Cloudflare's. Cloudflare does its own Brotli/gzip
  for compressible types. Not verified from here.
* WebSocket frames are not compressed; the 30 s application ping is a few bytes.

## 6. Measurements

See the table at the end of this page (filled from `TestWireMeasure`,
`OF_WIRE_MEASURE=1`).
