# OpenFamily Backend Security Audit

Date: 2026-10-25. Branch: `audit/baseline`. Scope: `backend/` (Go API, middleware, handlers, WebSocket hub, push/sms/apkrelease/serverupdate clients, config) plus `caddy/Caddyfile` and `docker-compose.yml` where they change backend behavior.
Method: static code review only. Go is not installed, so no tests were run and nothing was exercised dynamically. "Needs verification" marks claims that depend on third-party library behavior or deployment that was not run. This complements `docs/audits/SECURITY_AUDIT.md` (SEC-xxx); cross-references are given where they overlap.

## Findings summary

| ID | Severity | Title | Effort |
|----|----------|-------|--------|
| BSEC-001 | High | WebSocket streams are authorized only at connect; ex-members, logged-out users, deleted users and demoted platform admins keep receiving live locations | M |
| BSEC-002 | Medium | Client IP for rate limiting is taken from spoofable headers (chi `RealIP`); per-IP limits likely bypassable (needs verification) | S |
| BSEC-003 | Medium | Refresh tokens are stateless: no rotation, no reuse detection, 30-day lifetime, logout is all-sessions-or-nothing | M |
| BSEC-004 | Medium | Device ingest key survives logout, password change and admin reset; no device delete or key expiry | S |
| BSEC-005 | Medium | No request body size limits on most endpoints, and no server read/write/idle timeouts | S |
| BSEC-006 | Medium | In-memory rate limiter leaks memory per key, allows targeted login lockout, and leaves several endpoints unthrottled | M |
| BSEC-007 | Medium | Platform admin can read live and historical locations of every family with no audit trail | M |
| BSEC-008 | Medium | No usable MFA: TOTP is login-only with no enrollment, no replay guard, plaintext secret; admin accounts are password-only | M |
| BSEC-009 | Medium | Alert/SOS SMS fan-out can be abused to message arbitrary phone numbers and to spam a family | M |
| BSEC-010 | Low | Client-supplied alert lat/lon is not range-checked | S |
| BSEC-011 | Low | Public alert share page: no security headers, third-party script, location persists after resolve | S |
| BSEC-012 | Low | Account enumeration via register 409 and login timing | S |
| BSEC-013 | Low | Silent "location request" can be triggered by any family member (including child role) with no audit and no target notification | S |
| BSEC-014 | Low | No security headers on API responses (CORS itself is fine) | S |
| BSEC-015 | Low | Twilio auth token stored in plaintext in DB; Twilio error bodies (with phone numbers) are logged | S |
| BSEC-016 | Low | Admin domain probe makes a server-side HTTPS request to an admin-influenced host with redirects followed | S |
| BSEC-017 | Low | JWT parsing lacks required-exp/issuer enforcement; password policy and hash params are minimal | S |
| BSEC-018 | Low | Storage/DB amplification: per-point audit rows with no retention, 5000 pts/min batch ingest, unbounded devices | S |
| BSEC-019 | Low | Invite parameters unbounded; invite codes written to audit log in plaintext | S |
| BSEC-020 | Low | No step-up auth for account deletion or password change; current-password guessing is unthrottled | S |
| BSEC-021 | Info | Supply chain: APK sync and server updater trust GitHub with no checksum or signature | M |
| BSEC-022 | Info | Push payloads contain no coordinates; SOS SMS can contain coordinates; alert push names the sender even when `VERBOSE_PUSH=false` | S |

Checked and found fine (details in the last section): SQL injection, route-level authorization and family scoping, JWT algorithm pinning and token_version revocation, push SSRF defenses, CORS, WebSocket origin check, avatar upload handling, platform-admin gate.

## Route authorization map

Source: `backend/cmd/server/main.go:122-279`. "Scope" is what limits data to the caller. All authenticated routes sit behind `RequireAuth` (HS256, access type, expiry) and `RequireTokenVersion` (one DB read per request, `middleware.go:62-97`).

| Route | Who | Scope / check | Verdict |
|-------|-----|---------------|---------|
| GET /healthz, GET /config | public | static data | OK |
| GET /alerts/share/{token} | public bearer-token link | 128-bit random token, 24h TTL (`alerts.go:379-426`) | OK, see BSEC-011 |
| POST /auth/register, /auth/login, /auth/refresh | public | per-IP (+ per-email for login) rate limit | see BSEC-002/003/006/012 |
| GET /ws/stream | any user with a family | family resolved from DB at connect (`ws.go:104`) | see BSEC-001 |
| GET /api/admin/ws | platform admin | flag re-read from DB at connect (`admin_ws.go:58-67`) | see BSEC-001/007 |
| /me, /me/password, DELETE /me, /me/contacts*, /api/profile* | self | `WHERE id/user_id = claims.UserID` | OK |
| /families, /family, /family/leave, /family/join | self | caller's family from DB | OK |
| GET /family/members, /family/members/{id}/avatar | family member | `u.family_id = caller family`; avatar uses a caller/member family join (`family.go:342-350`) | OK |
| GET /family/members/{id}/history | family member (any role) | `familyHistoryAccess` caller family == target family (`history.go:119,172`) | OK; 403 vs 404 reveals that a UUID exists (Info) |
| POST /family/members/{id}/location-request | family member (any role) | same-family EXISTS query (`location_request.go:119-135`) | OK, see BSEC-013 |
| PATCH /family/members/{id}/role | family admin | family-row lock, admin recheck in tx, target `AND family_id` (`family.go:405-430`) | OK |
| POST /family/invites | family admin | caller family | OK, see BSEC-019 |
| /family/geofences*, /family/places* | member/admin (child excluded for writes) | every query carries `family_id = $n`; place/user ids validated against family (`geofence.go:219-240,388-410`) | OK |
| GET /audit | family admin | `family_id = $1 OR (family_id IS NULL AND user_id = $2)` | OK |
| /devices, PATCH /devices/{id}, POST /devices/{id}/ingest-key | self | `AND user_id = claims.UserID` | OK; no DELETE route (BSEC-004) |
| POST /alerts/check-in\|help\|sos | family member | family from DB; per-user limiter | see BSEC-009/010 |
| GET /alerts/{id}, POST /alerts/{id}/resolve | alert owner | `a.user_id = $2` (`alerts.go:96-100`) | OK |
| POST /devices/heartbeat, /locations, /locations/batch | Bearer or X-Device-Key | device `user_id` must equal claims user (`location.go:100`, `device.go:261`, `location_batch.go:194`) | OK; see BSEC-004 |
| /api/admin/* (26 routes) | platform admin | `RequirePlatformAdmin` re-reads flag per request (`middleware.go:83-105`) | gate OK; see BSEC-007 |
| GET /admin, /admin/* | public static SPA | CSP, nosniff, frame deny (`main.go:342-357`) | OK |

## Findings in detail

### BSEC-001 (High): WebSocket streams are authorized only at connect

Evidence:
- `ws.go:92-104` validates the JWT, token_version and family once, then `ws.go:137` registers the socket under that family id. The read loop (`ws.go:188-210`) never re-checks anything. Access tokens live 15 minutes (`config.go:181`) but the socket outlives them indefinitely; the server pings every 30 s (`hub.go:49-65`), so a healthy phone connection can last days.
- `hub.disconnectFamilyUser` exists (`hub.go:147`) but is called only from admin move/assign paths (`admin.go:477`, `admin_users.go:216`). It is not called from `LeaveFamily` (`family.go:191-255`), `Logout` (`auth.go:219-231`), `ChangeMyPassword` (`profile.go:209`), `AdminResetUserPassword` (`admin_users.go:285`) or `DeleteMe` (`profile.go:282`).
- Admin socket: `admin_ws.go:58-67` checks `platform_admin` only before `registerAdmin` (`admin_ws.go:88`); nothing closes it when the flag is revoked or the admin's password is reset.
- Broadcasts for locations, presence and alerts go to everything registered under the family id (`ws.go:298-322`, `hub.go:220-237`), including precise lat/lon.

Scenario: a teenager or ex-partner leaves the family (or is moved/deleted, or has their password reset after a phone theft). Their app keeps its open socket and continues to receive every member's live coordinates and SOS alerts until the TCP connection drops. A demoted or compromised platform admin session keeps receiving every family's live locations.

Fix: (1) call `disconnectFamilyUser` from LeaveFamily, DeleteMe, Logout, ChangeMyPassword and admin reset; add a `disconnectAdminUser`/close for demoted admins; (2) close the socket at access-token expiry (`claims.ExpiresAt`) and require the client to reconnect with a fresh token, or re-run `tokenVersionMatches` plus the family check on a timer (for example every 60 s) inside the writer loop; (3) cap sockets per user.
Effort: M.
Acceptance: integration test: connect, then leave family / logout / delete account / revoke platform admin, and assert the socket closes within 5 s and receives no further frames; test that a socket is closed at token expiry.

### BSEC-002 (Medium, needs verification): rate-limit client IP is spoofable

Evidence: `main.go:118` installs `chi/middleware.RealIP`, which rewrites `RemoteAddr` from `True-Client-IP`, `X-Real-IP` or `X-Forwarded-For`. `clientIP` (`audit.go:46-52`) trusts that value and feeds `authIPKey` (`ratelimit.go:30-32`) for login (20/15 min), register (5/h), refresh (60/15 min) and join (10/15 min). `caddy/Caddyfile:14-15` is a bare `reverse_proxy api:8080`; Caddy replaces `X-Forwarded-For` from untrusted clients but, as far as this review could establish, does not strip `True-Client-IP` or `X-Real-IP`. Exact chi v5.3.1 precedence was not run; confirm with a test request.
Scenario: an attacker rotates `X-Real-IP` per request and bypasses the register limit (open-registration servers, and Argon2 CPU/memory cost per request, `password.go:11-17`), the join-code guess limit, and the audit log records forged IPs. The per-email login limit (8/15 min) still holds.
Fix: remove `RealIP`; derive the client IP from the rightmost untrusted `X-Forwarded-For` entry only when `RemoteAddr` is in a configured trusted-proxy CIDR (the compose network), otherwise use `RemoteAddr`. Alternatively make Caddy set `header_up -True-Client-IP -X-Real-IP` and `header_up X-Real-IP {remote_host}`.
Effort: S.
Acceptance: test that requests with spoofed `X-Real-IP`/`True-Client-IP`/`X-Forwarded-For` from a non-proxy peer are rate-limited by the real peer address; 6 register attempts from one peer with varying headers yield 429.

### BSEC-003 (Medium): refresh tokens are stateless

Evidence: `auth.go:177-215` parses the refresh JWT and re-issues a new pair when `claims.TokenVersion` matches; nothing is stored (`jwt.go:513-529` has no `jti`). The old refresh token stays valid for its whole 30-day life (`config.go:182`). `Logout` bumps `token_version`, which kills every session of the user on every device (`session.go:5-12`).
Scenario: a stolen refresh token (backup, shared_preferences, see SEC-002) yields a silent, undetectable parallel session for 30 days; the victim's normal refresh does not invalidate it. The only revocation is logging out everywhere, which also breaks all the user's own devices.
Fix: add a `refresh_sessions` table (id=`jti`, user_id, device_id, token hash, issued/used/expires). Rotate on each refresh; if a used `jti` is presented again, revoke the whole session family and bump `token_version`. Support per-session logout.
Effort: M.
Acceptance: tests: refresh returns a new token and the old one yields 401; replay of a rotated token revokes the chain; logout of one session leaves other devices logged in.

### BSEC-004 (Medium): device ingest key outlives account credential changes

Evidence: `ingest_key.go:105-129` authenticates `X-Device-Key` by device id + SHA-256 hash only; it does not look at `users.token_version`, never expires, and is revoked only by rotation (needs a valid login) or by deleting the device row. There is no `DELETE /devices/{id}` route (`main.go:187-190`). Password change (`profile.go:209`), admin reset (`admin_users.go:285`) and logout bump `token_version` but do not touch `devices.ingest_key_hash`.
Scenario: a phone is stolen or its key leaked; the owner changes their password and logs out everywhere, yet the key holder can still post fake positions (spoofing the member's location to the family, triggering or suppressing geofence events, `location.go:243-247`) and heartbeats indefinitely.
Strength noted: the key is 256-bit random, hashed at rest, compared in constant time, and is scoped to the three ingest routes.
Fix: on password change/reset/logout (or an explicit "sign out device"), null `ingest_key_hash` for the user's devices (or all but the calling device); add `DELETE /devices/{id}`; optionally add `ingest_key_expires_at` or a last-used timestamp.
Effort: S.
Acceptance: after password change the old `X-Device-Key` returns 401; the delete route removes the device and its key; test for each.

### BSEC-005 (Medium): no body size limits or server timeouts

Evidence: `MaxBytesReader` is used only for batch ingest (`location_batch.go:156`) and avatars (`profile.go:418`). Every other handler decodes with `json.NewDecoder(r.Body)` unbounded, including pre-auth `Register` (`auth.go:47`) and `Login` (`auth.go:127`). `http.Server` sets only `ReadHeaderTimeout` (`main.go:281-285`): no `ReadTimeout`, `WriteTimeout` or `IdleTimeout`. Passwords have no maximum length (`auth.go:57`) and are fed to Argon2 (64 MiB each, `password.go:12-14`). The DB pool is capped at 10 connections (`db.go:20`) and every authenticated request holds one for the token-version query.
Scenario: an unauthenticated client streams a very large JSON body or slow-drips bodies to exhaust memory and connections; concurrent registrations or logins with large passwords exhaust memory (Argon2 allocation per request) and the 10-connection pool.
Fix: global `http.MaxBytesReader` middleware (for example 64 KiB default, per-route overrides for avatar/batch); set `ReadTimeout`, `WriteTimeout` (exempt WebSocket via hijack), `IdleTimeout`; cap password length (for example 256 bytes) and bound concurrent Argon2 operations with a semaphore.
Effort: S.
Acceptance: 1 MiB body to `/auth/login` returns 413; slow-body client is dropped at the timeout; a load test with 50 parallel logins stays under a fixed memory ceiling.

### BSEC-006 (Medium): limiter design weaknesses and coverage gaps

Evidence:
- `sms/limiter.go:29-41`: keys are never deleted, so each distinct key (login keys include the attacker-chosen email string, `ratelimit.go:35-37`; IP keys are spoofable per BSEC-002) leaves a permanent map entry. Unbounded memory growth.
- Per-email login key (`auth.go:132`) is charged before authentication and regardless of outcome: an attacker can lock a known victim out of login for 15 minutes with 8 requests (denial of service; cannot be told apart from the legitimate user).
- All limiters are process-local (`limiter.go:8-9`) and reset on restart.
- No limit on: `PATCH /me/password` current-password guesses (`profile.go:152-204`), `DELETE /me`, `POST /devices` (`device.go:59`), `/devices/heartbeat`, invalid refresh calls (which each write an `audit_log` row, `auth.go:190`).
Fix: evict empty/expired keys (periodic sweep); key login failures by (email, IP) and count only failures; add exponential backoff; add limits to the listed endpoints; consider Postgres- or Redis-backed counters if multi-replica.
Effort: M.
Acceptance: memory stays flat after 1M distinct keys; an attacker from IP A cannot lock out the same email from IP B; 429 after N wrong current-password attempts.

### BSEC-007 (Medium): platform admin location access is unaudited

Evidence: `/api/admin/ws` (`admin_ws.go:25-133`) streams every location, presence and alert frame for all families (`ws.go:298-322`, `alerts.go:290`) and sends a full snapshot with emails (`admin_ws.go:143-211`); `GET /api/admin/members` (`admin.go:149`), `/api/admin/members/{id}/history` (`history.go:135-167`) and avatars (`admin.go:195-221`) expose positions and 25-hour trails for anyone. None of these call `logAudit`. Admins can also reset any user's password (`admin_users.go:264-299`, audited) and move themselves into any family (`admin.go:421-479`, audited with the family id).
Scenario: a malicious or compromised operator account silently tracks any person on the server with no record for the family to see, which is the exact concern in SEC-007.
Fix: write an audit entry (family_id set so family admins see it) when an admin opens the admin socket and for every history/avatar/member-list read; show "server operator viewed location history" to family admins; optionally require a break-glass reason or per-family opt-in; add MFA (BSEC-008).
Effort: M.
Acceptance: each admin location read creates an `admin.location_view` audit row visible through `GET /audit` for that family; tests cover socket open, history read, member list.

### BSEC-008 (Medium): MFA is effectively unavailable

Evidence: `login` honors `totp_enabled` (`auth.go:160-166`) but no route enrolls, enables or disables TOTP (`GenerateTOTPSecret` in `totp.go:12` is unused; no handler writes `totp_secret`). If a secret is set out-of-band: no replay protection (same code accepted repeatedly within the 90 s skew window, `totp.go:29-35`), the secret is stored and read as plaintext (`auth.go:138`), there are no recovery codes, and failed TOTP is not separately limited. Platform admin accounts, the most sensitive in the system, are protected by a password plus 8 attempts per 15 min.
Fix: implement enrollment (setup + confirm), store the secret encrypted, track last-used time-step per user to reject replays, add recovery codes, offer WebAuthn or at least mandatory TOTP for platform admins.
Effort: M.
Acceptance: a TOTP code works once; a platform admin without MFA is refused when `REQUIRE_ADMIN_MFA=true`; tests for replay and enrollment.

### BSEC-009 (Medium): SMS fan-out abuse

Evidence: any user can store up to 10 arbitrary phone numbers as emergency contacts with no ownership verification (`contacts.go:74-124`); SOS sends an SMS to each (`alerts.go:229-234,348-368`) at 1 per 2 min per user (`alerts.go:150`, in-memory). `check-in` and `help` send an SMS to every family member's phone once per minute per user (`alerts.go:29,224-231`). Phone numbers on profiles are also unverified (`profile.go:100-120`).
Scenario: a user (or an attacker with a registered account on an open-registration server) enters a victim's number as an emergency contact and sends repeated SOS messages containing a link to their location, harassing a third party and burning the operator's Twilio balance; a member in a large family can generate 60 SMS per family member per hour.
Fix: verify contact/phone ownership (one-time code or contact opt-in) before the first SMS; per-recipient and per-day global caps; make check-in/help push/WS-only by default (SMS opt-in); persist limits in the DB; restrict SMS features to servers with invites required.
Effort: M.
Acceptance: an unverified contact receives no SMS; per-recipient daily cap returns 429 for the sender; test that check-in does not SMS by default.

### BSEC-010 (Low): alert coordinates unvalidated

Evidence: `alerts.go:160-190` accepts any float64 for lat/lon (the location ingest path checks ranges at `location.go:73-76`; alerts do not). Values are stored, broadcast and rendered in the share page (`alerts.go:473-481`, via `%f`, so no script injection).
Impact: a user can pin a false position on a SOS visible to family, admins and SMS recipients; large values break map rendering.
Fix: reuse the lat/lon range validation; prefer server-side last known position unless the client value is within a distance of it.
Effort: S. Acceptance: out-of-range alert coordinates return 400.

### BSEC-011 (Low): public share page hardening

Evidence: `alerts.go:379-403` serves HTML with only `Content-Type` and `Cache-Control`; no CSP, `Referrer-Policy`, `X-Frame-Options` or `X-Content-Type-Options`. The page loads Leaflet from unpkg (with SRI, `alerts.go:475-476`) and OSM tiles (which discloses viewed coordinates to the tile host). The token path has no rate limit. A resolved alert keeps showing its coordinates until 24 h pass (`alerts.go:396`, status is rendered but not enforced). Token entropy (128 bits) makes guessing infeasible.
Fix: add `Referrer-Policy: no-referrer`, a CSP restricting script/style/img hosts, `X-Frame-Options: DENY`; vendor Leaflet; hide coordinates once status is `resolved`; add a per-IP limiter; add `X-Robots-Tag: noindex`.
Effort: S. Acceptance: response carries the headers; resolved alerts show no map.

### BSEC-012 (Low): account enumeration

Evidence: `Register` returns 409 "email already registered" (`auth.go:104-107`) (when `RequireInvite` is set this needs a valid invite). `Login` returns early without running Argon2 for unknown emails (`auth.go:142-147`) while known emails take a full hash, giving a timing oracle; response bodies are otherwise identical.
Fix: always verify against a dummy hash for unknown users; return a generic registration response (email-confirmation style) or accept the 409 knowingly.
Effort: S. Acceptance: login timing difference for unknown vs known email under 5 ms in a benchmark test.

### BSEC-013 (Low): silent location requests

Evidence: `location_request.go:106-190`: any family member, including role `child`, can trigger a push-based refresh for any other member (cooldown 2 min per target, in memory). The command is intentionally silent on iOS (`Silent: true`, `location_request.go:300`), nothing is audited, and the target is not told who asked. `MaybeRequestStaleLocations` (`location_request.go:354-393`) also fires automatically when anyone opens the stream.
Impact: covert tracking within a family and push-volume abuse; the app is said to enforce its own sharing settings but the server has no record.
Fix: audit-log each request (requester, target), include requester name in the command so the target app can show it, allow members to disable remote requests.
Effort: S. Acceptance: an audit row is created per request; command JSON carries requester id.

### BSEC-014 (Low): no API security headers

Evidence: only the admin SPA sets headers (`main.go:352-357`). API/JSON responses have no `X-Content-Type-Options`, `Cache-Control: no-store` on sensitive endpoints, or HSTS (Caddy does not add HSTS by default).
CORS is fine: single configured origin, no credentials, no wildcard (`main.go:311-327`).
Fix: add a small middleware (`nosniff`, `Cache-Control: no-store` for authenticated routes, `Strict-Transport-Security` in Caddy).
Effort: S. Acceptance: header test on `/me` and `/healthz`.

### BSEC-015 (Low): Twilio secret handling

Evidence: `sms_settings` stores `auth_token` as plaintext (`sms_settings.go:195-203`); only the admin GET masks it (`sms_settings.go:127-141`). Twilio error bodies (up to 512 bytes, often containing the destination number) are logged by `slog.Error("alert: sms family", "err", err)` (`dispatcher.go:81`, `alerts.go:343`).
Fix: encrypt the token with a key from the environment, or document env-only credentials; redact phone numbers from logged errors.
Effort: S. Acceptance: DB dump contains no readable token; logs carry no full numbers.

### BSEC-016 (Low): admin domain probe

Evidence: `admin_domain.go:56-67` uses `http.DefaultClient` (follows redirects, no IP filtering) against `https://<host>/healthz`, where `host` comes from `SITE_ADDRESS` or the admin-editable `public_base_url` (`admin_domain.go:81-86`, `sms_settings.go:178`). The response status and the Go error string (connection refused vs timeout) are returned to the admin (`admin_domain.go:129-145`).
Impact: platform-admin-only blind SSRF/port-443 scanner of internal https hosts. Low because the actor is already fully trusted.
Fix: reject hostnames resolving to private/loopback ranges (reuse `push.isDisallowedIP`), disable redirects, return a generic detail.
Effort: S. Acceptance: setting `public_base_url` to an internal host yields "not allowed".

### BSEC-017 (Low): JWT and password hardening

Evidence: `jwt.go:532-551` pins HS256 and token type (good) but does not use `WithExpirationRequired`, `WithIssuer("openfamily")` or `WithAudience`; `exp` is validated only if present. Secret strength is only length >= 32 (`config.go:221`). Passwords: minimum 8 (`auth.go:57`), no breached-password or maximum check; Argon2id uses t=1, m=64 MiB, p=4 (`password.go:12-16`), acceptable but at the low end and never upgraded on login (stored parameters are trusted in `VerifyPassword`, fine unless the DB is tampered).
Fix: add parser options; rehash on login when parameters are below current; raise minimum length to 10-12; cap max length (BSEC-005).
Effort: S. Acceptance: token without exp is rejected; hash with old params is upgraded on login.

### BSEC-018 (Low): storage and DB amplification

Evidence: every stored location point writes an `audit_log` row (`location.go:236`) and `audit_log` has no retention (`000011_audit_log.up.sql`; retention exists only for `locations`, `000010`). Batch ingest allows 10 requests/min x 500 points = 5000 rows/min per user vs 120/min live (`location_batch.go:41,54`). `POST /devices` has no per-user cap and unbounded `name`/`app_version` lengths (`device.go:59`). A point timestamped +5 min (`maxTSSkew`) pushes `member_positions.ts` forward and blocks later live points (`location.go:131-134`, `location.go:211`), a self-inflicted outage.
Fix: stop auditing per point (or sample); add audit retention; cap devices (for example 20) and field lengths; reject future timestamps beyond 60 s; lower the batch rate or add a daily point budget.
Effort: S. Acceptance: audit table growth bounded in a soak test; 21st device returns 400.

### BSEC-019 (Low): invite hardening

Evidence: `normalizeInviteParams` (`invites.go:127-143`) accepts any `max_uses` and any `expires_in_hours` (huge values overflow `time.Duration` and may produce an already-expired or wrapped time); codes are 8 chars from a 32-letter alphabet, about 40 bits (`invites.go:28-31`). Join is limited to 10 per 15 min per IP (spoofable, BSEC-002). Invite codes are written verbatim into audit details (`invites.go:205-206,343-344`), readable by family admins (acceptable) and any DB reader.
Fix: bound `max_uses` (for example 50) and expiry (for example 30 days); store a hash of the code and show it once; per-code and per-account failure counters.
Effort: S. Acceptance: `expires_in_hours=10^12` returns 400.

### BSEC-020 (Low): no step-up for destructive account actions

Evidence: `DeleteMe` (`profile.go:230-290`) needs only a valid access token; `ChangeMyPassword` verifies the current password but is unthrottled (BSEC-006) and performs the hash update and token_version bump as two separate statements (`profile.go:197-216`).
Impact: a stolen 15-minute access token can delete the account and its history, or be used to guess the current password.
Fix: require the password (and MFA when enabled) for `DELETE /me`; make the password change and version bump one statement.
Effort: S. Acceptance: `DELETE /me` without password returns 400.

### BSEC-021 (Info): update and APK supply chain

Evidence: `apkrelease/github.go:220-390` downloads the first matching APK from the configured repo's latest `v*` release and the admin panel hands it out, with no checksum, signature or signing-certificate pinning. `nextLink` follows `Link: rel=next` URLs from the API response with the PAT attached (`github.go:236-261,371-372`); with the default API host this stays on GitHub. `serverupdate` (`github.go:61-123`) only reads. `AdminUpdateApply` (`admin_update.go:116-158`) triggers the updater sidecar, which pulls and deploys origin code (see SEC-001). `docker-compose.yml:83` passes `UPDATER_TOKEN` default empty; whether the sidecar then refuses all requests was not verified here (needs verification in `updater/main.go`).
Fix: verify APK signing certificate fingerprint and a published SHA-256 before serving; pin the release author; validate Link host equals the API host; require a non-empty updater token at startup.
Effort: M. Acceptance: a tampered APK is rejected; startup fails on empty token when `UPDATER_URL` is set.

### BSEC-022 (Info): push and SMS payload contents

Checked: no push payload contains coordinates.
- Geofence push: title only, `"A family member arrived at <place>"`; user name added only with `VERBOSE_PUSH` (`geofence_eval.go:800-808`); body is empty.
- Alert push: `"<FirstName> sent SOS[: note]"` (`alerts.go:428-442`); this includes the sender name even when `VERBOSE_PUSH=false` (the config doc in `config.go:65-71` says pushes omit the user), and includes the free-text note (280 chars) in the notification provider path. Align with the documented policy or document the exception.
- Location request: `{type, request_id, requested_at, expires_at}` only (`location_request.go:95-100`).
- WebSocket frames carry coordinates, but only to authenticated family members and platform admins.
- SMS: when `PUBLIC_BASE_URL` is not https the SMS body contains `"%.5f, %.5f"` coordinates (`alerts.go:458-465`), which transit Twilio and the carrier network. Prefer failing closed (no coordinates) or document it.
Effort: S.

## Checked and found fine

- SQL injection: every SQL call uses `$n` placeholders. The only `fmt.Sprintf` that builds SQL is `UpdateGeofence` (`geofence.go:431-451,496-505`), which concatenates fixed column fragments and parameter indices only; values go through `args`. No string-concatenated identifiers or user text reach SQL (checked by grep of `Query/QueryRow/Exec/Queue` sites and all backtick-plus-concatenation patterns).
- Family scoping: the queries in `family.go`, `place.go`, `geofence.go`, `history.go`, `alerts.go`, `contacts.go`, `device.go`, `audit.go` all constrain by caller family id or user id (see map above). No IDOR found. The geofence-state and event tables are reached only via family-validated geofence ids.
- JWT: HS256 pinned by method identity (`jwt.go:537`), token type enforced (`jwt.go:548`), token_version checked on every authenticated request (`middleware.go:62-97`) and on the ingest Bearer path (`ingest_key.go:95-100`) and at WS connect. Access TTL 15 min. Secret must be >= 32 chars and not the placeholder in all environments (`config.go:221`); this corrects SEC-004's statement that development mode accepts the default (the compose default value is rejected at startup; only the Postgres password and `sslmode=disable` defaults remain, and the latter is enforced only for `APP_ENV=production`, `config.go:224-230`).
- Platform-admin gate: re-read from DB per request (`middleware.go:83-105`); admin WS re-checks the same (`admin_ws.go:58-67`).
- Password hashing: Argon2id with random 16-byte salt, constant-time compare. Login errors identical for wrong email and wrong password (`auth.go:143,156`).
- Ingest-key middleware: constant-time hash comparison, device-id-bound, scoped to ingest routes; handlers re-verify device ownership.
- Push SSRF: UnifiedPush endpoints must be https, resolve to public addresses (loopback, private, link-local, CGNAT, benchmark ranges rejected), the dial is pinned to the validated IPs, redirects revalidated and cross-host redirects denied, no proxy env use (`push.go:82-208`); validated on registration (`device.go:290-293`) and again at send time (`push.go:262`). Redirect responses are read with a 512-byte limit.
- Other server-side fetches: GitHub API/asset clients use fixed hosts with token stripping on cross-host redirects (`github.go:392-404`); Twilio endpoint is fixed; updater URL is operator config.
- CORS: single static origin, no credentials, OPTIONS short-circuit (`main.go:311-327`); WebSocket `OriginPatterns` honors the same setting, same-origin default (resolves SEC-009; native clients send no Origin and are accepted by design).
- Tokens are never placed in URLs (WS uses header or subprotocol, `ws.go:87-90`).
- Avatars: content-type allow-list, 5 MiB `MaxBytesReader`, dimension and pixel caps with `DecodeConfig` before full decode, `nosniff`/private cache headers on read (`profile.go:20-26,418-461`).
- Admin SPA: strict CSP (script-src self + one hash), frame deny, nosniff (`main.go:342-357`).
- Logging: no tokens, passwords or coordinates are logged; the audit log stores emails only for login/register success and bootstrap events.
- Mass assignment: register does not accept role or family; role changes require admin inside a locked transaction; the last-admin invariant is enforced on leave, demote and delete.

## Suggested order of work

1. BSEC-001 (live-location leak after membership or credential change) and BSEC-004 (key survives credential reset).
2. BSEC-002, BSEC-005, BSEC-006 (abuse resistance: IP trust, size limits, limiter).
3. BSEC-007 and BSEC-008 (admin accountability and MFA), then BSEC-003 (refresh rotation) and BSEC-009 (SMS abuse).
4. Remaining Low/Info items as a hardening batch; add the authorization-matrix and WebSocket lifecycle regression tests as acceptance for each fix.
