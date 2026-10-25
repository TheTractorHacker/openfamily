# OpenFamily Performance Audit (Part A)

Branch `audit/baseline`. Method: static read of the code only. Nothing was executed, no database was queried, and no load was generated. **No performance number in this document was measured.** Every "likely" statement is reasoning from the code, and every figure in the benchmark and SLO sections is a proposed target, not an observation. Items that depend on runtime behaviour are labelled `needs verification`.

Paths are relative to `backend/internal/` unless noted. Citations are `file:line`.

## 1. Latency vocabulary (do not conflate these)

| Term | Definition | Where it is set in this code |
|---|---|---|
| GPS fix time | Time for the OS to produce a fix. Includes TTFF and the fix's own `ts`. | Client, outside server control. App asks for `LocationAccuracy.high`, `distanceFilter: 10` (`app/lib/services/location_reporter.dart:195-199`). |
| Device reporting interval | Gap between fixes the device chooses to send. | Foreground: stream filtered by 10 m, `minPostInterval` 5 s (`location_reporter.dart:84`). Background: 60 s interval, 50 m filter on one platform (`app/lib/services/background_location_service.dart:433-448`). Heartbeat 60 s (`location_reporter.dart:80`). |
| Server ingest latency | HTTP request received to commit and 2xx. | `location.go:41-283`. The geofence and WebSocket work is explicitly after the ack (`location.go:243-268`). |
| WebSocket delivery latency | Commit to frame written on the viewer's socket. | `ws.go:298-322`, `hub.go:220-237`, `hub.go:48-70`. Includes an extra DB lookup and goroutine start. |
| End-to-end freshness | Wall-clock age of the pin on a viewer's screen = (now - fix time). Sum of GPS fix age + device wait + network + server + WS + client render. | Not measured anywhere. |

Consequence: the server can only improve the ingest and WS terms. For a moving member, the device interval (5 s foreground, 60 s background by design) dominates end-to-end freshness by one to two orders of magnitude over server work, unless the DB is saturated. Server SLOs must be set on the server terms only, and freshness reported separately with device-side timestamps.

Note a clock caveat: `ts` is the device's fix/clock time (`location.go:77-90`), while `last_seen_at` / presence use the server receipt time (`location.go:178-180`, `location.go:262`). Freshness computed as `server_now - ts` mixes device clock skew (allowed up to 5 min, `location.go:20`) into the number.

## 2. Findings

Severity is expected impact at scale, by reasoning. Effort S/M/L.

### PERF-001 (High): Geofence reconcile scans the whole `locations` hypertable every 60 s
- `geofence_eval.go:436-441`: `SELECT DISTINCT ON (d.user_id) ... FROM locations l JOIN devices d ... ORDER BY d.user_id, l.ts DESC` has no `WHERE ts >` bound. Run every `geofenceReconcileInterval` = 60 s (`geofence_eval.go:30`, started at `cmd/server/main.go:114`).
- Reasoning: ordering by `d.user_id` (a devices column) with `l.ts DESC` cannot be satisfied by `idx_locations_device_ts (device_id, ts DESC)` alone (`db/migrations/000001_init.up.sql:94`). The planner will likely join and sort a large share of all chunks (up to 90 days of rows). Cost grows with total retained rows, not user count. Plan shape `needs verification` with `EXPLAIN (ANALYZE, BUFFERS)`.
- It then calls `evaluateGeofences` for every user, sequentially (`geofence_eval.go:448-460`), each doing 1 family query + 1 candidate query + a transaction per candidate. Offline or idle users are re-evaluated every minute forever.
- Fix: read the latest point from `member_positions` (already the latest-state table, `000012_member_positions.up.sql`) instead of the hypertable, and only for users whose `ts` is newer than their `geofence_states.last_seen_ts`. Effort S.

### PERF-002 (High): Per-point ingest does a hypertable `MAX(ts)` under a user row lock
- `location.go:116-134`: `SELECT ... FROM users WHERE id=$1 FOR UPDATE`, then `SELECT MAX(l.ts) FROM locations l JOIN devices d ... WHERE d.user_id=$1` on every point.
- Reasoning: `MAX` across a join over a hypertable must consult every chunk's `(device_id, ts DESC)` index for each of the user's devices (about 13 chunks at default 7-day chunks over 90 days; see PERF-004). Chunk exclusion cannot help because there is no time predicate. Planning time scales with chunk count. This runs inside the lock and holds a pooled connection (PERF-006). `member_positions.ts` already holds the same value for the monotonicity decision and is a single-row PK read (the batch path's guard already uses it, `location.go:211`). Caveat: `member_positions.ts` only updates when a point is stored (not on dedup, `location.go:156-167`), same as `MAX(locations.ts)`, so semantics match. Effort S.
- The row lock serializes all of one user's ingests (intended, `location.go:105-108`) but also blocks any other transaction that touches that `users` row (profile updates, token_version bump, DeleteMe, role change) for the duration. `needs verification` under contention.

### PERF-003 (High): Round trips per stored point (write amplification)
By count from the code, one stored live point costs approximately: token-version check (`middleware/middleware.go:61`, or the ingest-key equivalent, `needs verification` of the key path's queries), device owner lookup (`location.go:94`), BEGIN, user lock, MAX(ts), member_positions read, locations INSERT, member_positions upsert, devices UPDATE, COMMIT, audit INSERT (`location.go:236`, separate non-tx Exec), then in goroutines: family lookup for geofence (`geofence_eval.go:79`), candidate query (`:101`), at least 1 transaction (3-4 statements) per candidate geofence, and family lookup for broadcast (`ws.go:306`). That is roughly 14 plus 4 per candidate geofence database round trips per point. This is a count from reading, not a measurement. 
- `devices.last_seen` is updated on every point (`location.go:156,220`), a hot-row update that creates a dead tuple each time; `member_positions` likewise. Tune with fillfactor and HOT-friendly layout; `needs verification` of bloat.
- Effort M: collapse lookups (cache family id and token_version with short TTL or put them in the JWT-verified path), merge `devices.last_seen` into the member_positions upsert, make audit async or sampled.

### PERF-004 (High): Hypertable has default chunking, no compression, no continuous aggregate
- `000001_init.up.sql:92` `create_hypertable('locations','ts', if_not_exists=>TRUE)` with no `chunk_time_interval` (TimescaleDB default is 7 days; `needs verification` of the installed version's default). No compression policy anywhere: `grep -ri compress backend/` returns nothing. No space dimension, no continuous aggregate.
- Indexes: `(device_id, ts DESC)` (`:94`) and GiST on `geom` (`:95`). The GiST index is written on every insert and no query in the reviewed handlers uses a spatial predicate on `locations` (history filters by device/time, reconcile uses DISTINCT ON). It is probably dead weight on the hottest write path. Confirm with `pg_stat_user_indexes.idx_scan` (`needs verification`); then drop or defer it. Effort S.
- Row width: `geom` + 6 doubles + 2 text columns per row, no `(device_id, ts)` uniqueness. Compression with `segmentby=device_id, orderby=ts DESC` would typically shrink such data substantially, but any ratio is `needs verification` on real data.
- Retention: fixed `add_retention_policy('locations', INTERVAL '90 days')` (`000010_location_retention.up.sql:4`), duplicated as constant `maxHistoryAge` (`history.go:18`) and in docs (`PRIVACY.md:15`). Chunk-granular drop means data between 90 and 97 days can remain; users are told "90 days" and `parseHistoryRange` rejects older (`history.go:205-207`). Configurable retention needs a per-installation setting driving `remove_retention_policy`/`add_retention_policy` (a global policy only; per-circle retention would need row-level deletes). Cross-reference GAP-009.

### PERF-005 (Medium): No uniqueness on `(device_id, ts)`; dedup is application-side and racy
- Comment states it is deliberate (`location_batch.go:102-104`). Live path avoids dups only by the `ts > MAX(ts)` rule under the user lock (`location.go:131`). The batch path does a `SELECT ts ... ANY($2)` then inserts, with no user lock and no `ON CONFLICT` (`location_batch.go:246-248`, `282-293`). Two concurrent retries of the same batch (client crash-resend is documented, `app/lib/services/location_outbox.dart:24-28`) can both pass the dedupe query and insert duplicates. A batch racing a live point with the same `ts` can also duplicate. `needs verification` by concurrent test.
- Consequence: duplicate rows distort trails, visits, and any future trip distance/duration. Fix: `CREATE UNIQUE INDEX ON locations (device_id, ts)` (legal on a hypertable because `ts` is included) and `INSERT ... ON CONFLICT DO NOTHING`, which also removes the pre-query. Effort S-M (migration must dedupe existing rows first; index build on a large table needs a maintenance window).

### PERF-006 (High): Connection pool of 10 vs. unbounded goroutines and long transactions
- `db/db.go:25` `MaxConns = 10`; other pool settings left at pgx defaults (min conns, max conn lifetime/idle, health check: `needs verification` of defaults for the pinned pgx version).
- Each ingest holds a connection across about 7 statements inside a transaction with a row lock. After commit, every ingest spawns up to two unbounded goroutines (`location.go:173-180`, `243-268`) each acquiring connections with 30 s / 10 s timeouts. There is no concurrency cap, queue, or shed. Under a burst (e.g. many devices reconnecting and draining outboxes, or a stalled DB), goroutines pile up waiting on the pool and every request in the system including auth, history, and WS snapshots competes for the same 10 connections.
- The geofence processing holds a transaction with `FOR UPDATE` on the geofence row (`geofence_eval.go:168`) and then performs push dispatch only after commit (`:405`), which is good. But `dispatchGeofencePush` is sequential per device with up to 30 s each (`:58`, `:701-746`) in its own goroutine; slow push endpoints do not hold DB connections (`needs verification` that the loop releases rows before the HTTP call).
- Fix: expose `DB_MAX_CONNS`, size from CPU and `max_connections`, add a bounded worker pool or channel for post-commit geofence work keyed by user, consider PgBouncer. Effort M.

### PERF-007 (Medium): Geofence evaluation cost per update
- Candidate query (`geofence_eval.go:101-117`) casts `p.geom::geography` inside `ST_DWithin`; the only GiST index is on the geometry column (`000001_init.up.sql:62`), so it cannot be used and the query becomes a scan of the family's geofences/places. Per-family counts are small, so this is likely cheap, but cost is O(places in family) per point and runs even for dedup'd stationary points (`location.go:173-177`). Candidates also include every geofence the user is currently inside or has no state for, so a user sitting inside "Home" opens a transaction (`processGeofence`) on every report (about every 60 s in background). Roughly 4-5 statements per inside-geofence per report. Fix: skip the transaction when `inside` is unchanged and state is fresh, using a lock-free read or an in-memory last-state cache; or store the place in a precomputed form with a projected geometry index. Effort M.
- Dedup'd stationary points re-run geofence evaluation by design (`location.go:146-152`). This is correct for dwell/pending semantics but is the hottest repeated work; pending transitions are also fired by the 60 s reconcile worker (`geofence_eval.go:467`), so the per-report evaluation of stationary users may be redundant for debounce purposes. `needs verification` of whether any behaviour depends on it.
- Debounce 60 s constant (`geofence_eval.go:25`) is global, not per-geofence or per-circle.

### PERF-008 (Medium): Accuracy is not filtered on ingest; the live map is exposed to bad fixes
- `IngestLocation` validates only lat/lon ranges and timestamps (`location.go:73-90`). Accuracy is stored as given and no minimum quality is enforced. A 5 km cell-tower fix will overwrite `member_positions` (`location.go:203-217`) and move the live pin, fire geofences, and be broadcast. Accuracy filtering exists only in history (`history.go:33`, `261-272`, threshold 100 m, read-time) so bad points still occupy storage.
- The stationary dedup anchors on whatever was last stored (`location.go:138-155`), so a poor first fix can anchor the dedup radius at a wrong spot until the user moves more than 25 m from it.
- Fix: server-side policy (reject or flag when `accuracy > N` unless no better fix has arrived for T), and use accuracy-aware dedup (do not dedup against a low-accuracy anchor). Effort S.

### PERF-009 (Medium): Out-of-order and duplicate timestamp handling is inconsistent across paths
- Live path rejects anything not strictly newer than the user's max stored ts, with a 400 (`location.go:131-134`). The client treats failure by queueing to the outbox (`location_reporter.dart:323-326`), which replays via batch. So a legitimately late point from a second device of the same user (multi-device users, check across `d.user_id`) is rejected, then replayed as history: it appears in history but never moves the live pin (guarded by `member_positions.ts < EXCLUDED.ts`, `location.go:211`). That is the right outcome but costs a failed request plus a batch round trip. Metrics for 400 rates are not emitted (`needs verification`: no metrics package found).
- Because dedup'd points are not stored, the `MAX(ts)` check compares against the last stored point, not the last accepted one (`location.go:131`). A replay of a dedup'd point's timestamp is accepted.
- Batch path trusts device ordering inside the batch by sorting (`location_batch.go:260`), but each point's `member_positions` upsert is a separate statement (`location_batch.go:282-293`). 500 points = 500 upserts of one row, producing 500 dead tuples. Compute the newest point in code and upsert once. Effort S.

### PERF-010 (Medium): WebSocket fan-out is bounded and non-blocking but has no coalescing, no sequence/resume, and per-update DB lookup
- Good: per-client buffered channel (64, `hub.go:13`), non-blocking send, slow client dropped (`hub.go:229-236`), single writer goroutine, 30 s protocol ping with 10 s timeout (`hub.go:49-65`), read limit 4 KiB (`ws.go:130`), JSON marshalled once per broadcast (`ws.go:311`), idle fast path when nobody connected (`ws.go:301-303`).
- Gaps: (a) the writer's `conn.Write(ctx, ...)` uses the request context with no per-write deadline (`hub.go:54`), so a stalled peer blocks the loop until the buffer fills and a broadcast evicts it; the ping case cannot run while blocked in Write. (b) Dropping is silent: no sequence number, no "resync" frame; the client must infer loss and reconnect to receive a full snapshot (`ws.go:154-166`). `needs verification` of client reconnect logic in `app/lib/services/family_service.dart`. (c) No coalescing: 64 queued stale positions for a member are delivered in order rather than latest-wins. (d) Each broadcast calls `familyIDForUser` (DB round trip, `ws.go:306`) although the ingest already loaded `dbFamilyID` (`location.go:117`), and a separate lookup happens in geofence evaluation. (e) Admin sockets receive every location of every family (`ws.go:321`, `hub.go:199-216`); one slow or numerous admin set costs O(admins) per update. (f) Single global mutex for register/unregister/broadcast copies (`hub.go:74-78`, `220-227`), fine at small scale. (g) Fan-out is per family, so with future multi-circle membership (GAP-001) a single update must fan out to several rooms and honour per-circle sharing permissions.
- Single-process, in-memory hub: not usable across API replicas; the in-memory rate limiter is likewise not shared (`sms/limiter.go:8-9`). Horizontal scaling needs Postgres LISTEN/NOTIFY or Redis pub/sub. Effort L.

### PERF-011 (Medium): Members snapshot query aggregates the entire `devices` table
- `ws.go:235-238` and `family.go:283` (`needs verification` of the second): `LEFT JOIN (SELECT user_id, MAX(last_seen) FROM devices GROUP BY user_id) d`. The subquery is not restricted to the family's users. Whether the planner pushes the filter down through the join is `needs verification` with EXPLAIN; if not, every WebSocket connect and reconnect aggregates all devices on the server. Reconnect storms (server restart, mobile network flaps) multiply this. Fix: `LEFT JOIN LATERAL (SELECT MAX(last_seen) FROM devices WHERE user_id = u.id)`. Effort S.
- A snapshot is also taken on every reconnect (`ws.go:154`) and each connect runs `MaybeRequestStaleLocations` (`ws.go:172`), which can trigger pushes to members (rate limited per `location_request.go`, 15 min cooldown). Reconnect loops therefore have a push side effect. Cross-reference notifications (GAP-016).

### PERF-012 (Medium): History query shape, bounds, and downsampling
- `history.go:275-281`: join `devices`, filter `d.user_id = $1 AND l.ts >= $2 AND l.ts < $3`, `ORDER BY l.ts`, returns every row in the range (range capped at 25 h, `history.go:17`, error text says "one day"). All rows are fetched, filtered for accuracy in Go (`:261-272`), then downsampled to 30 s buckets with a 1500-point cap (`history.go:19-20`, `322`), and visit detection runs over all points. Downsampling happens after transfer from the DB to the app server.
- Reasoning: at a 5 s foreground interval a day could hold up to about 17,000 rows per device. Memory and transfer are modest, but rows are wide, `ST_Y`/`ST_X` is evaluated per row, and the time predicate allows chunk exclusion while the device join uses the `(device_id, ts)` index. Likely acceptable for one-day pulls; it will not extend to multi-day trips, route playback, or export (GAP-005, GAP-009, GAP-010). Use `time_bucket` / `first/last`, or a continuous aggregate, for coarse zoom; keep raw for playback by cursor.
- The 100 m accuracy gate is applied at read time only and falls back to raw points when everything fails the gate (`history.go:268-270`).
- `loadFamilyPlaces` is a second query per request (`history.go:298-305`); fine.
- Access check: caller/target family is checked, but there is no per-member or per-circle history permission (GAP-001).

### PERF-013 (Medium): Rate limits and batch limits
- Live: 120 points per user per minute, sliding window in memory (`location.go:25-26`, `47`). Batch: 10 requests/min, each up to 500 points and 1 MiB (`location_batch.go:41`, `54-55`, `49`). Worst-case batch inserts per user per minute = 5,000 points, with two statements each (`:282-293`) in one transaction. A compromised or buggy client can generate 5,000 inserts plus 5,000 upserts per minute per user. Consider a per-user points-per-window budget instead of request count.
- The limiter is an in-memory map of timestamp slices, never evicting keys (`sms/limiter.go:29-40`): keys for departed users persist until process restart (slow growth). It does not coordinate across replicas. Keyed by user, not by IP/device, so a leaked device key only throttles that user, which is fine.
- Single-point rate limit 120/min exceeds the client's design (min 5 s spacing, `location_reporter.dart:84`), so it only catches abuse.
- Per-ingest audit INSERT (`location.go:236`) writes an unbounded table with no retention (`grep` found no purge for `audit_log`; `000011_audit_log.up.sql:13-14` indexes). At 1 row per stored point this can rival the `locations` row count. Remove from hot path, or log only security-relevant events. Effort S.

### PERF-014 (Low-Medium): Push retry model and its latency/duplication behaviour
- Initial dispatch: per device, inner retry 3 attempts with 2 s backoff, 30 s budget (`geofence_eval.go:36-39`, `58`, `871-`). Reconcile re-dispatch only for events older than 15 min and up to 3 total attempts (`:44`, `:53`). So a failed alert can be delayed by 15+ minutes before a second try, and the final failure is dead-lettered silently (`deadLetterDevice`, `:860`). Per-device delivery state exists (`000007_per_device_push_tracking.up.sql`), which is a good basis for delivery states (GAP-013) but there is no read API for it.
- Initial dispatch is sequential across devices (`:701-746`): a family with many devices where one endpoint stalls delays the others by up to 30 s each. Parallelise with a small bounded pool. Effort S.
- Alert (SOS/help) path uses a different fan-out (`alerts.go:218-290`); the delivery guarantees there are `needs verification` (no per-recipient delivery table exists in migrations: `000020_alerts.up.sql`).

### PERF-015 (Low): HTTP server settings
- `http.Server` sets only `ReadHeaderTimeout` (`cmd/server/main.go:281-285`); no `ReadTimeout`, `WriteTimeout`, `IdleTimeout`, or `MaxHeaderBytes`. Single-point ingest does not apply `MaxBytesReader` (the batch path does, `location_batch.go:446`), so a large JSON body to `/locations` is read in full. Effort S. Do not add a blanket WriteTimeout without exempting the WebSocket route.

### PERF-016 (Low): Latest-location state vs historical storage
- Positive: `member_positions` is a separate one-row-per-user latest-state table (`000012_member_positions.up.sql`), PK on `user_id`, upsert guarded against regression (`location.go:211`). It survives retention drops. The live map and WS snapshot read it, not the hypertable (`ws.go:234`). This is the right design.
- Gaps: it is per user, not per device (multi-device users overwrite each other; `device_id` is recorded), and per user, not per circle. It carries `ts` (fix time) and `updated_at` (receipt time) but on dedup only `updated_at` moves (`location.go:161-167`), so "last seen" has two meanings across clients (`ws.go:33-38`). Define one freshness contract (Section 4).

## 3. Proposed benchmarks (to be measured; none have been run)

All against a production-shaped stack (Postgres + Timescale + PostGIS, same image as `docker-compose.yml`), with Postgres and server on separate CPU cores, and `pg_stat_statements` enabled.

1. Single-point ingest throughput and latency (covers PERF-002, 003, 006). Tool: k6 or vegeta posting `/locations` for N synthetic users, one device each, monotonically increasing `ts`, movement above the 25 m dedup radius. Ramp N = 10, 100, 1,000, 5,000 reporting every 5 s and every 60 s. Record p50/p95/p99 request latency, 429/400/5xx rates, pool wait time (`pgxpool.Stat()` AcquireDuration/EmptyAcquireCount), Postgres CPU, WAL volume.
2. Dedup ratio: replay a stationary trace (jitter within 5-15 m) and verify rows written per hour vs 200 response `deduplicated`.
3. Geofence cost: vary geofences per family (1, 10, 50) and users inside vs outside, measure the post-ack goroutine duration and statements per point (`pg_stat_statements` calls delta).
4. Reconcile scan cost (PERF-001): with `locations` loaded to 1M, 10M, 100M rows, `EXPLAIN (ANALYZE, BUFFERS)` the query at `geofence_eval.go:437-441`; record the wall time of `reconcileGeofencesOnce` and its interaction with ingest p99.
5. Batch backfill: 500-point batches at 10/min per user, then concurrent duplicate batches to confirm or refute PERF-005; count duplicate `(device_id, ts)` rows afterwards.
6. History: 1 day at 5 s / 60 s cadence, 1, 10, 100 concurrent requests; record DB time vs Go time (downsample and `detectStays`, `history.go:391-527`). Repeat for a 30-day range prototype for playback.
7. WebSocket: 1,000 / 10,000 idle sockets; fan-out of one update to families of 5 and 50 members; measure commit-to-delivery latency using client-side receipt vs a server-embedded send timestamp (same host clock). Include a slow-reader test (stop reading) to confirm the drop at 64 frames and measure the reconnect + snapshot cost (PERF-011).
8. Reconnect storm: kill the server, restart, have 5,000 clients reconnect with jitter and without; track snapshot query time and pool exhaustion.
9. Storage: ingest 10M rows, measure table + index size per row, with and without the GiST index, and with compression enabled; measure query time on compressed vs uncompressed chunks.
10. Retention: confirm chunk drop timing and lock behaviour of `drop_chunks` during ingest (`needs verification`).
11. End-to-end freshness (device-instrumented): a test app build logs fix `ts`, send time, ack time, and WS receipt time on a second device; report each segment separately (Section 4). This is the only way to quantify GPS fix time and device interval, and it requires physical devices.

## 4. Proposed SLOs (targets to adopt after baselines exist, not claims)

Define separately and do not sum into one number without showing the parts.

| SLI | Proposed target (to be validated) | Measured at |
|---|---|---|
| Ingest latency (request received to response), single point | p95 under 150 ms, p99 under 500 ms at agreed load profile | server, per-request |
| Ingest availability (non-4xx-client-error success) | 99.9 percent monthly | server |
| Ingest-commit to WS-write (server internal fan-out) | p95 under 250 ms | server, histogram around `broadcastLocation` |
| WS delivery to connected client | p95 under 1 s from commit | test client with synthetic probes |
| Pool acquire wait | p99 under 50 ms | pgxpool stats |
| Geofence transition detected after ack | p95 under 5 s | server, from commit to event insert |
| Geofence push dispatch (event insert to first provider 2xx) | p95 under 10 s | server |
| History day request | p95 under 1 s for 1 day | server |
| Duplicate rows per (device, ts) | 0 | nightly SQL check |
| Live-map freshness (moving member, foreground) | report as `fix age at ingest + server + WS`, target for server+WS share under 2 s | device-instrumented |

Freshness reporting rule: publish four series, never one: `fix_age_at_send` (device), `send_interval` (device cadence), `server_ack_latency`, `ws_delivery_latency`. Background-mode freshness is bounded below by the 60 s interval (`background_location_service.dart:433`) and the OS power manager; the server cannot fix that.

Metrics to add (none found in the reviewed code, `needs verification`): per-route histograms, pool stats, count of 400 "not newer", dedup rate, WS clients gauge, dropped-slow-client counter, reconcile duration, push attempts by outcome.

## 5. Suggested order of work

1. PERF-001 and PERF-002 (S each, large effect on cost growth), PERF-005 (unique index plus ON CONFLICT).
2. PERF-006 pool configuration and post-commit worker bound.
3. PERF-011, PERF-009 batch single upsert, PERF-013 audit removal.
4. PERF-004 compression and chunk interval decision, tied to the configurable-retention design (GAP-009).
5. PERF-010 sequence/resync frames and coalescing; replica-safe pub/sub only if multi-instance is a goal.
6. Add metrics, then run the Section 3 benchmarks and replace this document's reasoning with measurements.
