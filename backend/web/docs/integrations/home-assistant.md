# Home Assistant integration

Orbitly can feed a Home Assistant (HA) you run yourself: who is home, battery, optionally GPS, places, and
arrival / departure / SOS / possible-crash / trip / low-battery events. Everything is **read-only** and opt-in.

Parts:

| Part | Where |
|---|---|
| Integration tokens, read API, webhook delivery | server: `backend/internal/handlers/ha_*.go`, migration `000170_ha_integrations` |
| "Integrations" card (create / revoke tokens, webhook, test, snippets) | admin panel, Settings |
| HACS-style custom component | `integrations/home_assistant/custom_components/openfamily/` ([README](../../integrations/home_assistant/README.md)) |

## Quick start

1. Admin panel, **Settings, Integrations**: *Create a token*. Pick the circles HA may see and what it may read. Copy the token (shown once).
2. In HA add the **Orbitly** integration (see its README to install it), enter your server URL and the token.
3. Optional push: on the token open **Webhook**, paste the URL HA shows in the integration's *Configure* dialog, and put the signing
   secret from step 1 into that dialog. Use **Send test event**.

Without the custom component the API is plain JSON, so a REST sensor works too (the card shows a ready-made snippet).

## Tokens

* Format `ofha_` + 43 base64url characters (256 random bits). Only `SHA-256(token)` is stored. The token and the webhook signing secret are
  returned **once**, by `POST /integrations/ha/tokens`. Lists show a 4-character hint only.
* Owned by the creating user. Any adult account (admin or member, not a child account) can create tokens for circles they are a live member of;
  other circle ids answer a uniform 404. Max 10 active tokens per user, 10 creations per hour.
* **Scopes** (all read): `presence`, `location` (implies presence), `places`, `events`, `driving`.
* **Circle scope**: a non-empty list of the owner's circles. A token only sees a circle while its owner is still a live member.
* **Authority**: a token never exceeds what its owner sees as a circle member. It does not use platform-admin powers, so
  `ADMIN_LOCATION_ACCESS` is neither needed nor bypassed: a platform admin's token sees the same circles an ordinary member would.
* **Bound to the owner's credentials**: a token stops working (401, webhook stops) when its owner changes or resets their password, uses "log out everywhere", changes two-factor settings, or becomes a child account. Create a new token afterwards. (Migration `000171`: `owner_token_version`.)
* Revocation is immediate (`DELETE /integrations/ha/tokens/{id}`), clears the webhook URL and secret, and the next API call is 401.
* `last_used_at` is updated at most once a minute. Audit log (`GET /audit`, family admins): `integration.ha.token_created`,
  `token_revoked`, `webhook_updated` (host and last 4 characters of the path only), `webhook_secret_rotated`, `webhook_test`,
  `read` (at most one row per token per 15 minutes) and `auth_failed` (at most one per address per 15 minutes).
* Rate limits: 120 requests/min per token (429 + `Retry-After`), 30 bad-token attempts per address per 15 minutes (a /64 for IPv6), 60 management calls/min, 6 test-fires/min.

## What a token can learn (privacy rules)

| Situation | Result |
|---|---|
| Normal circle, member shares location | state, battery, speed, last seen; lat/lon/accuracy **only with the `location` scope** |
| Member turned sharing off or paused sharing | listed with `state: "sharing_off"`, nothing else |
| **Private (E2EE) circle, no trusted server device** | member listed with `state: "unavailable_private_circle"`, `location_available: false`; **no coordinates, battery, speed or timestamps**, not even for the token's owner. `places` returns nothing for it; arrival / departure / trip / low-battery events are not produced. The circle shows `state: "unavailable_private_circle"` in `circles`. |
| Private circle in **trusted-server mode** (server holds plaintext) | behaves like a normal circle |
| Member in both a readable and a Private circle of the token | located through the readable circle only |
| SOS / crash in a Private circle | the event and the `sos_active` flag exist (the server knows an alert was raised), with `location: {available: false, reason: "unavailable_private_circle"}` and no position |
| SOS / crash while the member paused sharing (or sharing is off in the alert's circle) | event delivered, `location: {available: false, reason: "sharing_off"}`; a position needs a readable circle **and** active sharing in it |
| Arrival / departure at a place that was deleted later | shown only if the circle recorded when the event was queued is one the token reads through; otherwise hidden |
| SOS without the `location` scope | `location: {available: false, reason: "scope"}` |

The readability test is the same SQL used elsewhere: `NOT e2ee_plaintext_blocked(circle)` plus `sharing_enabled` and no active sharing pause.
See [docs/design/E2EE.md](../design/E2EE.md) and [PRIVACY.md](../../PRIVACY.md).

## API (`/integrations/ha/v1`, `Authorization: Bearer ofha_...`)

| Route | Scope | Notes |
|---|---|---|
| `GET /ping` | any | token name, scopes, circles with `state` |
| `GET /members` | `presence` | `members[]`: `id`, `name`, `state` (`home`, `not_home`, place name, `unknown`, `unavailable_private_circle`, `sharing_off`), `place`, `battery_pct`, `speed_mps`, `last_seen`, `location` (lat, lon, accuracy_m; `location` scope), `driving` (`driving` scope), `sos_active` / `crash_active` (`events` scope), `location_available`, `unavailable_reason` |
| `GET /places` | `places` | zones of readable circles (id, name, type, lat, lon, radius_m) |
| `GET /events?after=<id>&limit=` | `events` | the pull side of the webhook (same filtering). Without `after` it only returns `next_after`; history is never dumped |

Errors: 401 `invalid_token` (also for revoked tokens and for user session tokens), 403 `insufficient_scope`, 429 `rate_limited` / `too_many_requests`.
Management (session auth, owner only): `GET/POST /integrations/ha/tokens`, `PATCH/DELETE /integrations/ha/tokens/{id}`, `POST /integrations/ha/tokens/{id}/test`.

### Not available

* `charging`: the apps do not report it.
* SSE / WebSocket: not implemented. Use the webhook, or `GET /events` as the pull equivalent.

## Webhook delivery

Event kinds: `arrival`, `departure`, `sos`, `crash`, `trip_start`, `trip_end`, `low_battery` (plus `test`). The sources are the existing
tables (geofence transitions, SOS alerts, crash reports, trips) copied into a short-lived outbox without coordinates, plus the existing low-battery
detector. The outbox only fills while at least one token with the `events` scope exists, and a webhook never receives history from before it was set.
Trips are segmented after the fact, so `trip_start` and `trip_end` arrive together some minutes after the drive ended (`occurred_at` is the real time).

Request: `POST` JSON `{"id", "type", "occurred_at", "member": {"id","name"}, "place"?, "location"?, "data"?}` with headers

```
X-OpenFamily-Event: arrival
X-OpenFamily-Delivery: <event id>
X-OpenFamily-Timestamp: <unix seconds>
X-OpenFamily-Signature: v1=<hex HMAC-SHA256(secret, "<timestamp>.<raw body>")>
```

Receivers must verify in constant time, reject timestamps more than 5 minutes off, and de-duplicate by event `id` (delivery is at-least-once). The custom component does all three.
A shared test vector keeps the Go signer and the Python verifier in step (`TestHAWebhookSignatureVector`, `test_webhook_auth.py`).

Retry: a failed delivery (non-2xx, timeout, refused, blocked) is retried in order with exponential backoff 30 s, 1 min, 2, 4, 8 minutes (capped at 15); after 6 consecutive failures that single event is dropped and the next one is tried.
The card shows the last delivery's result (HTTP status or an error class: `blocked_address`, `dns_error`, `timeout`, `tls_error`, `connection_failed`, `http_<code>`, `redirect_not_followed`, `invalid_url`).
HA's own certificate is verified: for a LAN HA with a self-signed certificate use `http://` on the LAN or a valid certificate.

### Target URL policy (SSRF)

* `http` / `https` only, no credentials, no fragment, length <= 512, valid port.
* **Always refused**: loopback, link-local (including `169.254.169.254` and `fe80::/10`), unspecified, multicast, broadcast, reserved ranges, known metadata addresses
  (`100.100.100.200`, `fd00:ec2::254`, `168.63.129.16`), deprecated site-local, 6to4 and Teredo; IPv4-mapped and NAT64 forms are unwrapped first.
* **Private LAN** (RFC 1918, `fc00::/7`, CGNAT `100.64/10` such as Tailscale): refused unless the token's *"Home Assistant is on my local network"* option is on.
  That option can be set **only by a platform administrator** and only counts while the owner is still one. A public HTTPS address (for example Nabu Casa) needs nothing.
* Checked at save time (name resolves, every address allowed) **and again at connect time on the resolved IP**, so DNS rebinding after saving cannot reach a blocked address.
  No proxy, no redirects, 10 s timeout, response bodies are discarded (only the status code and an error class are ever stored).

## Trust paths: adversarial self-review

Reviewed against the code as shipped. "Fixed" means a change made during this review.

| Path | Question | Finding |
|---|---|---|
| Token at rest | Does a DB read yield a usable token? | No: SHA-256 of 256-bit random tokens; the plaintext exists only in the one response. A DB read does expose `webhook_secret` in clear (it is needed to sign): it lets an attacker forge deliveries to the HA webhook, but only with HA's secret webhook id as well; it cannot read anything. Rotate with *New signing secret*. Not encrypted at rest (residual risk, accepted). |
| Token lookup timing | Can the hash lookup leak a token? | The lookup is by SHA-256 of the presented token through a btree index. An attacker cannot choose hash prefixes, so comparison-time differences do not help brute force. Format is checked first (cheap 401). |
| Token in logs | Can a token reach logs or audit? | Only the `Authorization` header carries it. The router logs no headers; audit rows contain token ids, paths without query, host and last four path characters of webhook URLs, error classes. API responses to the owner mask the URL. The webhook URL is never written to the audit log in full (checked). |
| Session vs integration token | Can a user JWT call the HA API, or an `ofha_` token the user API? | No: the HA API accepts only the `ofha_` shape and the user API only JWTs (separate middleware); both covered by `TestAuthzMatrixHAAPI`. |
| Cross-family / IDOR | Can A mint or use a token for B's circle? | Creation requires live membership (uniform 404). A token naming a foreign circle sees nothing (membership is re-read per request). Management routes are owner-only with a uniform 404 for others, revoked or malformed ids (authz matrix with a family-B token fixture and snapshot comparison). |
| Revoked / out-of-scope | Do they stop immediately? | Yes: revoked tokens 401 on the next call and their webhook URL and secret are cleared; a missing scope is 403; leaving a circle drops it from the token's view with no action. |
| Private circle | Can any path leak a position? | Members: gated per circle by `e2ee_plaintext_blocked`, including the owner's own entry. Places: only readable circles. Events: re-gated at delivery; SOS positions come from `alerts.lat/lon`, which the SOS path already withholds for blocked circles, and are gated again. Outbox rows hold no coordinates. Tests: `TestHAMembersPrivacy`, `TestHAServerMemberCircleDeliversCoordinates`, `TestHASOSPositionOnlyWhenAllowed`, `TestHAEventsVisibilityAndPoll`. Residual: if a circle was Private and its members' earlier plaintext rows still exist from before it was switched, they are not exposed here because the gate is on circle state, not on data. |
| SSRF | Can a user make the server call internal services? | Blocked classes above; dial-time guard defeats DNS rebinding and alternate IP spellings (the check is on the connected address); no redirects, no proxy; responses not reflected. Only a platform admin can open the LAN, and the public side (any public host:port) is inherent to webhooks; the failure class is shown only to the token owner. Fixed during review: also block 6to4, Teredo and site-local IPv6, and re-check that the owner is still a platform admin before each LAN delivery. |
| Webhook replay | Can a captured delivery be replayed to HA? | The signature covers the timestamp; HA rejects anything more than 5 minutes old or from the future, and de-duplicates by signed event id and by delivery header (the header is unsigned, so the body id is what counts). Memory-only caches: a replay after an HA restart inside the 5 minute window is possible and would at worst re-fire one event. |
| Signature timing | Constant-time compare? | The HA verifier uses `hmac.compare_digest`; it hashes nothing before checking the timestamp window and fails closed on a missing secret. The server never verifies incoming signatures. |
| Amplification / DoS | Can a token burn server resources? | Per-token and per-address limits, `GET /events` scans at most 100 outbox rows per call, deliveries are limited to 25 events per target per 5 s tick, 8 targets in parallel, 10 s timeout, outbox pruned after 7 days. A permanently failing target delays its own queue only (about 15 minutes per dropped event). Rate limiters are in memory and reset on restart. |
| Elevation | Do tokens grant admin power? | No: owner-level read of the chosen circles; `ADMIN_LOCATION_ACCESS` is untouched. Account deletion cascades to tokens; password changes/resets, "log out everywhere", two-factor changes and a downgrade to a child account invalidate the owner's tokens (found in the second review round and fixed: tokens are bound to `users.token_version` and the adult-role check is repeated on every request and delivery). |

## Operations

* Migration `000170` adds `ha_integrations`, `ha_events`, `ha_event_cursors` and an index on `trips(ended_at)`; the down migration drops them.
* The background loop (`RunHAIntegrations`) idles unless a token with `events` exists.
* Single-instance assumption for delivery (duplicates are possible but harmless with HA's de-duplication).

## Tests

* Go: `backend/internal/handlers/ha_integrations_db_test.go` (tokens, privacy gating, IDOR, scopes, rate limits, events, signed delivery with retry, SSRF) and `cmd/server/authz_matrix_test.go` (new routes and `TestAuthzMatrixHAAPI`). Need `TEST_DATABASE_URL`.
* Web: `web/test/integrations.test.mjs`.
* Python: `integrations/home_assistant/tests`.
