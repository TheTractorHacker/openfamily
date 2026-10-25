# OpenFamily Feature Gap Analysis (Part B)

Branch `audit/baseline`. Static read only; nothing was run. Status values: **exists** (implemented end to end by the evidence cited), **partial**, **missing** (no evidence found after searching backend, app and migrations). Anything that could not be confirmed from source is labelled `needs verification`. Effort: S (days), M (1-3 weeks), L (more than 3 weeks or architectural). Milestones follow `ROADMAP.md`: M3 circles and accounts, M4 tracking and maps, M5 notifications and safety, M6 UX.

Paths relative to repo root. Backend route table: `backend/cmd/server/main.go:122-258`. Migrations: `backend/internal/db/migrations/`. Cross-references to `PERFORMANCE_AUDIT.md` use PERF ids.

## Summary table

| ID | Capability | Status | Effort | Milestone |
|---|---|---|---|---|
| GAP-001 | Multiple circles per user | partial (UI only) | L | M3 |
| GAP-002 | Per-circle permissions | partial | M | M3 |
| GAP-003 | Per-circle places | partial | M | M3 |
| GAP-004 | Per-circle history permissions | partial | M | M3 |
| GAP-005 | Per-circle chat | missing | L | M5 |
| GAP-006 | Per-circle notification settings | missing | M | M5 |
| GAP-007 | Real-time location + live map | exists | S (polish) | M4 |
| GAP-008 | Movement state, driving detection, speed units | partial | M | M4 |
| GAP-009 | Configurable history retention | missing | M | M4 |
| GAP-010 | Trips and route playback | missing | L | M4 |
| GAP-011 | Data export (user and Dawarich) | missing | M | M4 |
| GAP-012 | Geofences with debounce | exists | S | M5 |
| GAP-013 | SOS / help / check-in with delivery states | partial | M | M5 |
| GAP-014 | Emergency contacts | exists | S | M5 |
| GAP-015 | Email/password auth | exists | S | M3 |
| GAP-016 | Native push | partial | M-L | M5 |
| GAP-017 | TOTP two-factor | partial (enrollment missing) | M | M3 |
| GAP-018 | Biometric app lock | exists | S | M3 |
| GAP-019 | Device and session management | partial | M | M3 |
| GAP-020 | Password reset (self-service) | missing | M | M3 |
| GAP-021 | Account deletion | exists (gaps) | S | M3 |
| GAP-022 | In-app chat | missing | L | M5 |
| GAP-023 | Search | missing | M | M6 |
| GAP-024 | Dawarich export | missing | M | M4 |

(GAP-022 supersedes the narrower per-circle chat in GAP-005; build once.)

## Detail

### GAP-001: Multiple circles per user. partial (UI only). L. M3
- Schema allows one family per user: `users.family_id UUID REFERENCES families(id)` single column (`000001_init.up.sql:20`); no membership join table exists in any migration (`000001`-`000024`).
- API enforces it: `CreateFamily` rejects a user who already has a family (`backend/internal/handlers/family.go:42-52`), `LeaveFamily` nulls the column (`family.go:242`), JWT/WS resolve exactly one family (`handlers.go:139-149`, `ws.go:104`).
- The app has multi-circle scaffolding: `app/lib/widgets/circle_switcher.dart:9-29` (a list of circle names), `app/lib/screens/families_screen.dart`, `join_circle_screen.dart`, `create_circle_screen.dart`. Whether the switcher can ever hold more than one entry against this backend is `needs verification`; the single-family API suggests it cannot.
- Needed: `circle_members(circle_id, user_id, role, ...)` table; migrate `users.family_id` into it; make every handler take a circle id; WebSocket subscribes to several circles (PERF-010 g); `member_positions` stays per user but visibility becomes per circle. This is the largest refactor and gates GAP-002 to GAP-006. Do the authorization-matrix tests first as the roadmap says (`ROADMAP.md`, M3).

### GAP-002: Per-circle permissions. partial. M. M3
- Roles are per user, not per membership: `users.role IN ('admin','member','child')` (`000001_init.up.sql:23-24`), changed via `PATCH /family/members/{id}/role` (`main.go:171`, `family.go:429-455`). Invite codes carry a role (`000014`/`000023_reconcile_invite_codes.up.sql`, `role`, `max_uses`, `expires_at`).
- No granular permissions (share location on/off per circle, who can see history, who can edit places). Children's email redaction is the only visible policy (`ws.go:281-284`).
- Needed: move role to the membership table (GAP-001), add a permission set per role, and a central authorization function with tests.

### GAP-003: Per-circle places. partial. M. M3
- Places belong to one family: `places.family_id` (`000001_init.up.sql:51-58`); CRUD routes `/family/places` (`main.go:180-183`); geofences link place and user (`000001:65-74`, unique indexes `000003_geofence_refinements.up.sql:238-239`). Place types: home, school, work, custom, gym (`000017_place_type_gym.up.sql`). Address column `000009_place_address.up.sql`.
- Works for one circle per user. With multiple circles, the same real place needs either a per-circle copy or a shared place with per-circle geofences. Decide in M3.

### GAP-004: Per-circle history permissions. partial. M. M3
- `GET /family/members/{id}/history` requires only same family (`history.go:92-121`, `familyHistoryAccess` at `:172`). Any member can see any other member's day trail and visits, including children viewing adults; no owner opt-out and no per-circle toggle. Platform admins can read any member's history (`history.go:135`, `main.go:231`), which is also a privacy decision to document.
- Needed: per-membership "share history" setting, honoured by history, WS location, geofence events and export.

### GAP-005: Per-circle chat. missing. L. M5. See GAP-022.

### GAP-006: Per-circle notification settings. missing. M. M5
- No notification preferences table in migrations. Geofence enter/exit flags are per geofence (`geofences.enter_notify`, `exit_notify`, `000001_init.up.sql:70-71`); debounce is a global constant (`geofence_eval.go:25`). Alerts fan out to every family member regardless of preference (`alerts.go:293-322`). No quiet hours, per-member mute, or per-event-type opt-out.
- Needed: `notification_prefs(user_id, circle_id, event_type, channel, enabled)`; honoured by geofence push (`createEventDeviceRows`, `geofence_eval.go:752`) and alert fan-out.

### GAP-007: Real-time location and live map. exists. S. M4
- Ingest `location.go:41-283`, offline backfill `location_batch.go:145-238`, WS stream `ws.go:81-216` with members snapshot, location and presence frames (`ws.go:293-356`), last-known state in `member_positions` (`000012_member_positions.up.sql`). App map `app/lib/screens/map_screen.dart`, reporter `app/lib/services/location_reporter.dart`, background service `background_location_service.dart`, member clustering `app/lib/utils/member_clustering.dart`. On-demand refresh request `location_request.go` (`POST /family/members/{id}/location-request`, `main.go:170`).
- Gaps are performance and robustness (PERF-001, 002, 006, 008, 010, 011), not features. Add tracking profiles (see GAP-008).

### GAP-008: Movement state, driving detection, speed units. partial. M. M4
- Wire field `motion_state` is stored free-text (`location.go:62`, `000001_init.up.sql:88`). Foreground reports send an empty string (`location_reporter.dart:277`). Android background fills it from activity recognition; iOS does not (comment at `app/lib/services/member_mapper.dart:300-304`).
- "Driving" is inferred client-side only: any speed of 5 m/s or more upgrades to car, lower speed keeps the previous badge (`member_mapper.dart:304-308`); labels at `member_mapper.dart:229`, `:295`; icons `app/lib/widgets/movement_icon.dart`. No server-side movement state machine, no hysteresis, no trip start/stop, so history shows only the stored `motion_state` strings (`history.go` majority label `:607`).
- Speed units: server stores m/s (`speed_mps`); the app hard-codes mph via `* 2.23694` (`member_mapper.dart:60`, `:145-146`). No unit setting found in `app/lib/screens/settings_screen.dart` (`needs verification` of the full file); no km/h option.
- Needed: user unit preference (mph/km/h, also distance), a defined movement-state enum and server-side derivation shared with web, adaptive tracking profiles (moving/stationary/low battery) to replace fixed 10 m / 50 m filters (`location_reporter.dart:195-199`, `background_location_service.dart:433-448`).

### GAP-009: Configurable history retention. missing. M. M4
- Fixed at 90 days in four places: Timescale policy (`000010_location_retention.up.sql:4`), API gate `maxHistoryAge` (`history.go:18`, `:205-207`), `PRIVACY.md:15`, `README.md:134,545`. `member_positions` is the only thing that survives (`000012`).
- Needed: instance setting (and later per-circle or per-user override) stored in a settings table; API to change it; job to re-apply `remove_retention_policy`/`add_retention_policy`; UI in the admin SPA; exported privacy text derived from the setting. Per-user retention requires row-level deletes since chunk drop is global (PERF-004). Pair with compression (PERF-004) so longer retention is affordable.

### GAP-010: Trips and route playback. missing. L. M4
- No trips table or endpoint. History returns a downsampled day trail (30 s buckets, 1500 point cap, `history.go:19-20`) and visits typed place/stop/transit (`history.go:43-52`, `detectStays :391`, `fillTransit :547`). `app/lib/screens/day_detail_screen.dart` renders a day; no playback control or per-trip stats (distance, max speed, duration, score). `grep -ri playback` found no route playback implementation (`needs verification` of web SPA bundle).
- Needed: trip segmentation (server-side, from movement state, GAP-008) into a `trips` table, raw-point retrieval by trip with cursor paging, playback UI in app and web, unique `(device_id, ts)` (PERF-005) so distance is correct. History range limit is 25 h (`history.go:17`) and must be lifted for trips.

### GAP-011: Data export. missing. M. M4
- No export endpoint in the route table (`main.go:122-258`). The only export-like strings are `location_outbox.dart` internals. Users cannot download their own data; the privacy promise "you own the data" (`README.md:75`) is deployment-level only.
- Needed: authenticated export of profile, devices, places, locations (GPX/GeoJSON/CSV), events, alerts; streaming and size-limited (PERF-012 shows the current history path is not suited to bulk reads). Serves GDPR-style requests alongside GAP-021.

### GAP-012: Geofences with debounce. exists. S. M5
- Full pending/notified state machine with first-observation baseline, stale-point guard, fixed 60 s debounce, 60 s reconcile worker, per-device push tracking and retry (`geofence_eval.go:14-58`, `152-406`, `411-`; `000002`, `000003`, `000005`-`000008`). Routes `main.go:175-178`. App side `geofence_service.dart`.
- Gaps: debounce is global and not configurable per geofence; circular only (radius on a point place, `000001_init.up.sql:56-57`); no dwell-time alerts, no schedules; no user-visible event feed beyond `geofence_events` (`needs verification` of an events list endpoint: none in the route table). Performance issues PERF-001, 007.

### GAP-013: SOS, help, check-in with delivery states. partial. M. M5
- Exists: `POST /alerts/check-in|help|sos`, get, resolve (`main.go:192-196`, `alerts.go:58-135`), once-per-window limiter (`alerts.go:150`), push to family and SMS to family and emergency contacts (`alerts.go:218-367`), public share page with token (`alerts.go:379-493`, `share_token`), status `active|resolved` (`000020_alerts.up.sql`), resolve notifies "is safe" (`alerts.go:237-265`).
- Missing: no per-recipient delivery state. The alerts table has only `status active|resolved`; there is no alert-recipient table (`000020_alerts.up.sql`). Fan-out is fire-and-forget in a goroutine with errors logged only (`alerts.go:343`, `:365`). The sender cannot see who was notified, who acknowledged, or that SMS failed. SMS needs Twilio configured by the operator (`sms/dispatcher.go:19`; admin settings `main.go:246-248`); without it, emergency contacts silently get nothing (`needs verification` of user-facing signal). Only one alert per window per user (`alerts.go:150-153`) may block a legitimate second SOS.
- Needed: `alert_deliveries(alert_id, recipient, channel, state queued/sent/delivered/failed/acked, attempts, error)`; recipient acknowledgement; retry with escalation; sender-visible status; reuse the per-device pattern of `geofence_event_devices` (`000007`).

### GAP-014: Emergency contacts. exists. S. M5
- Table with validation and uniqueness (`000018_emergency_contacts.up.sql`), API `main.go:153-155`, app `emergency_contact_service.dart`, `contact_picker.dart`, `models/emergency_contact.dart`, SMS fan-out `alerts.go:348-367`. No update/edit route (create and delete only), no verification that a contact consented, no per-contact channel preference.

### GAP-015: Email/password auth. exists. S. M3
- Register/login/refresh/logout (`main.go:130-132`, `152`; `auth.go:121-`), argon2/bcrypt hashing in `internal/auth/password.go` (`needs verification` of algorithm and cost), JWT with `token_version` revocation (`000021_token_version.up.sql`, `middleware.go:52-71`), per-IP and per-email rate limits (`ratelimit.go:8-17`), invite-gated registration on managed servers (`invites.go`, `main.go` RequireInvite).
- No email verification, no email delivery of any kind (no mailer found: `grep -ri smtp` empty). That blocks GAP-020.

### GAP-016: Native push. partial. M-L. M5
- iOS via APNs HTTP/2 with provider JWT; Android via UnifiedPush/ntfy only (`push/push.go:3-6`, `223-`); no FCM (`grep` of `app/pubspec.yaml` finds none, `needs verification`). Without a UnifiedPush distributor installed, Android users get no push; the app registers `unifiedpush_endpoint` (`000001_init.up.sql:41`, `app/lib/services/unifiedpush_bridge*.dart`, `push_service.dart`).
- Retry model: 3 attempts, 2 s backoff, redispatch after 15 minutes, dead-letter after 3 attempts (`geofence_eval.go:36-58`, PERF-014). No delivery receipts, no collapse keys or priority/TTL control reviewed (`needs verification`), no coordinates policy yet (roadmap M5 "payloads without coordinates"; alert SMS and share URL embed location, `alerts.go:458`).
- Needed: optional FCM path, privacy-preserving payloads, delivery state, priority for SOS.

### GAP-017: TOTP. partial. M. M3
- Server verifies TOTP at login when `totp_enabled` (`auth.go:160-163`), helpers exist (`auth/totp.go:12,24,29`), the app login can send `totp_code` (`app/lib/services/api_client.dart:167-174`).
- No enrollment or disable endpoint is routed (`main.go:148-153` lists no `/me/totp`), and no handler writes `totp_secret` or `totp_enabled` (grep of handlers shows only SELECTs and RETURNING). Therefore TOTP cannot be enabled through the product (`needs verification`: an operator could set the columns in SQL). No recovery codes, no UI. Login also does not enforce TOTP for refresh.
- Needed: setup (QR/URI), confirm, disable (with password), recovery codes, admin reset, app and web screens.

### GAP-018: Biometric. exists. S. M3
- `app/lib/services/biometric_service.dart`, `widgets/biometric_app_lock.dart`, `session_gate.dart`, settings toggle (`settings_screen.dart`), `local_auth` dependency. It is an app lock, not a credential: it does not gate server-side sensitive actions. Roadmap SEC-002 covers secure credential storage separately.

### GAP-019: Device and session management. partial. M. M3
- Devices: register, list, rename/update, rotate ingest key (`main.go:187-190`, `device.go:194`), `last_seen`, `app_version`, platform. Per-device ingest key stored hashed (`000024_device_ingest_keys.up.sql`).
- Missing: no `DELETE /devices/{id}` route (devices only vanish with the account via ON DELETE CASCADE); no revoke-single-device; no session list (JWT access tokens plus refresh, revocation is global via `token_version` bump on logout/password change, which signs out all devices at once: `000021`). No new-device alert, no "sign out other devices" except password change.
- Needed: refresh-token table with device binding, session list/revoke API and UI, device removal that also clears push tokens and ingest key.

### GAP-020: Password reset (self-service). missing. M. M3
- Only an admin can reset another user's password (`PATCH /api/admin/users/{id}/password`, `main.go:237`); authenticated change-password exists (`main.go:150`). No forgot-password endpoint, no reset token table, no email transport (GAP-015). On a self-hosted instance the realistic design is operator-delivered reset links or optional SMTP settings mirroring `sms_settings` (`000022_sms_settings.up.sql`); `app/lib/main.dart` matched a loose grep but a reset flow was not found (`needs verification`).

### GAP-021: Account deletion. exists (gaps). S. M3
- `DELETE /me` (`main.go:151`, `profile.go:227-`) with transaction, family lock, last-admin check (`profile.go:263-`); app confirmation dialog (`settings_screen.dart:333-362`); public page `site/delete-account.html`. Cascades remove devices and `locations` (`devices.user_id ON DELETE CASCADE`, `locations.device_id ... ON DELETE CASCADE`, `000001_init.up.sql:36-37,80`), `member_positions` and alerts (`000012`, `000020`).
- Gaps to verify: audit log rows keyed by user id (`000011_audit_log.up.sql`) and any other retained copies; no password re-authentication or grace period (`needs verification` in `profile.go:227-330`); no export-before-delete (GAP-011); deletion of the last admin's family handling beyond what is shown is `needs verification`.

### GAP-022: Chat. missing. L. M5
- No chat tables in migrations, no routes, no app screens (`grep -ri chat` in `backend/internal` and `app/lib` matches only unrelated words). Needs a messages table, per-circle rooms, delivery/read state, push, retention, moderation for child accounts, and WS message types beyond the current five (`welcome`, `members`, `location`, `presence`, `avatar`, plus `pong`; `ws.go`). Define E2E-or-not early; it changes storage and push payload design.

### GAP-023: Search. missing. M. M6
- Nothing for members, places, or history search beyond the geocoding scaffold, which is disabled by default and points at a self-hosted Nominatim with a TODO to move behind a backend endpoint (`app/lib/services/geocoding_service.dart:8-33`). `place_picker_screen.dart` depends on it. No backend `/geocode` or search route in `main.go`.
- Needed: backend geocode proxy (privacy and rate limits), member/place search, history by place or date.

### GAP-024: Dawarich export. missing. M. M4
- `ROADMAP.md` lists it as optional: "design doc and issues first". No code. Dawarich ingests points via its API (OwnTracks/Overland-style payloads and its own points API; exact current contract `needs verification` against the Dawarich docs before design).
- Needed: opt-in per user, scheduled or incremental push of stored points (`locations` by `(device_id, ts)`, so unique key PERF-005 helps idempotency), secrets storage for the Dawarich URL and API key, cursor table, and a consent UI. Depends on GAP-011 (shared serializer) and GAP-004 (permissions: a user may export only their own points).

## Dependency order

1. GAP-001 (membership schema) then GAP-002, 003, 004, 006.
2. PERF-005 (unique `(device_id, ts)`), GAP-009 (retention setting), GAP-008 (movement state) then GAP-010 (trips), GAP-011 and GAP-024 (export).
3. GAP-013/016 delivery-state design shared across geofence pushes, alerts and chat (GAP-022).
4. Account hardening cluster: GAP-017, 019, 020 together (they share the session/token model).

## Method notes and limits

- Checked: `backend/cmd/server/main.go` routes, handlers `location*.go`, `hub.go`, `ws.go`, `geofence_eval.go`, `history.go`, `alerts.go`, `family.go`, `profile.go`, `auth.go`, all `db/migrations/*.up.sql` names (read in full: 000001-000003, 000005-000008, 000010, 000012, 000018, 000020-000024), and targeted app greps under `app/lib`. The embedded web admin bundle (`backend/web/dist`) and the web SPA source (`web/`) were not read in depth, so web-side features (for example a TOTP screen) are `needs verification`.
- Not executed: no tests, builds, or runtime behaviour were exercised.
