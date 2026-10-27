# Live tracking (Life360-style moving pin)

Contract between the backend and the Flutter reporter/map. All changes are
additive; old clients keep working.

## Data flow

1. Reporter (driving, or while "watched") sends a fix every ~1-2 s:
   `POST /locations` (Bearer or `X-Device-Key`).
2. Server validates, stores the fix (moving fixes are never deduplicated),
   upserts `member_positions` (never moves backwards), returns 201.
3. After commit, the server broadcasts a `location` WebSocket frame to every
   connected member who may see the reporter (circle membership + sharing
   enabled, evaluated per frame).
4. Map clients interpolate between frames using `ts`, `speed_mps`, `heading_deg`.
5. Offline backlog: `POST /locations/batch` (history only, no WS frames).

## Frame: WS `location`

```json
{"type":"location","user_id":"<uuid>","lat":1.0,"lon":2.0,
 "ts":"2026-01-01T12:00:00Z","last_seen_at":"2026-01-01T12:00:01Z",
 "battery_pct":80,"speed_mps":13.4,"heading_deg":271.5,
 "motion_state":"driving","accuracy_meters":6.0,"circle_id":"<uuid, optional>"}
```

- `ts`: GPS fix time (use for interpolation); `last_seen_at`: server receipt.
- `speed_mps`, `heading_deg` (degrees clockwise from north), `accuracy_meters`,
  `battery_pct`, `motion_state`: nullable (null/absent when unknown).
- `heading_deg` is also in the members snapshot (WS `members` frame and
  `GET /family/members`), nullable.
- `place_presence` (members snapshot and `GET /family/members` only, not `location`
  frames; omitted when unknown or location-hidden): `{"place_id","place_name",
  "state":"at"|"left","since":"<RFC3339>"}`, derived from the latest geofence
  enter/exit events (no extra storage). "at" = arrived at `since` and not yet
  exited; "left" = last exit at `since`. Powers "At Home since 3:42 PM" /
  "Left Work 25 min ago".

A fix whose `ts` is not newer than the stored position is rejected (400) on
`POST /locations`, so the pin never moves backwards.

## Stationary dedup (unchanged intent)

A fix is collapsed (HTTP 200 `{"status":"deduplicated","ts":...,"live":bool}`, a `presence` frame
instead of `location`) only when it is within 10 m of the stored position AND
`speed_mps` is absent or <= 1.5. Any fix with `speed_mps` > 1.5 or moved
>= 10 m (radius widens to the fix's own `accuracy_meters`, capped at 25 m, when it is worse than 10 m) is stored and broadcast every time.

## Rate limits

- `POST /locations`: 300 per minute per user (5 Hz sustained headroom; 1 Hz
  needs 60). Runaway loops still get 429.
- `POST /locations/batch`: 60 per minute per user, up to 500 points each.
- `POST /locations/watch`: 30 per minute per user (1 call per ~15 s is normal).

## Watch / live boost

Viewer opens the map on a member and calls every ~15 s while looking:

`POST /locations/watch`
```json
{"user_id":"<target uuid>","circle_id":"<optional uuid>"}
```
Response 200:
```json
{"status":"watching","ttl_s":45,"boost":true}
```
- Authorization is identical to reading the target's location: the viewer must
  share a circle with the target and the target must be sharing with the viewer
  (and, if `circle_id` is given, in that circle). Otherwise 404
  (`member not found`) - no probing. Self-watch returns 200 with
  `{"status":"self"}` and does nothing.
- The watch lapses 45 s after the last call. While at least one watch is live,
  the target is "boosted".
- When a boost starts (or restarts after lapsing), the server sends the target's
  devices one direct push (SSE `/push/stream`, same channel as
  `location_request`; also UnifiedPush/APNs silent fallbacks):
  ```json
  {"type":"live_boost","ttl_s":60}
  ```
  At most one command per target per 30 s regardless of watcher count. While
  watches keep renewing, the command is re-sent about every 45 s (ttl 60 s) so a
  push-only device stays boosted.
  It carries NO coordinates and no viewer identity.
- Foreground reporters without push learn the state from the ingest response:
  `POST /locations` 201 and 200 (deduplicated) bodies gain `"live": true` while boosted
  (omitted/false otherwise). Reporter should send every ~1-2 s while
  `live` is true or `live_boost` was received (until ttl), else its normal
  cadence.

## Privacy rationale

Boost only exists while someone with permission is actively looking (watch
TTL 45 s, renewed by the viewer's open map). A member who paused sharing
cannot be boosted; the server also refuses. Push payloads never contain
position. State is in memory only; a restart simply ends boosts.

## Hot path notes (per accepted fix)

Database round trips for `POST /locations` (moving fix): 1 transaction =
BEGIN, device-ownership check + user row lock (one statement), last-position
read, `locations` INSERT, then member_positions upsert + device heartbeat
pipelined in one round trip, COMMIT. The audit-log row is written at most once
per user per minute. After the ack, the WebSocket broadcast costs ONE query
(own + sharing circles via `OwnAndSharingCircles`) and no per-viewer queries;
geofence evaluation runs asynchronously on a bounded worker pool.

### Measured

`BenchmarkIngestMoving` (`backend/internal/handlers/live_test.go`, real
TimescaleDB pg16 in Docker on a heavily loaded shared host, 1000-fix runs):
about 8 ms per moving-fix `POST /locations` (full handler, including commit),
i.e. one core could sustain >100 fixes/s; 1 Hz x several members is negligible.
Before replacing the `users ... FOR UPDATE` row lock with a per-user advisory
lock the same benchmark measured ~280 ms/op on the same host (the row lock
dirtied the hot `users` page and forced a WAL write per fix).
Run: `TEST_DATABASE_URL=... go test ./internal/handlers -run x -bench IngestMoving`.
