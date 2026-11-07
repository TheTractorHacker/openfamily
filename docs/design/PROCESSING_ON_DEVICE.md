# On-device processing: trips, driving reports, weekly summary (Phase 0 of PRIVACY_PROCESSING.md)

Status: spike, code and tests landed, **not wired into any screen** (phase 5 does that).
Code: `app/lib/services/processing/` (pure Dart, no Flutter imports, safe in a background isolate).
Tests: `app/test/processing/`. Shared fixtures produced by the real Go code: `testdata/processing/*.json`.
Go fixture generators: `backend/internal/trips/processing_fixtures_test.go`, `backend/internal/handlers/processing_fixtures_test.go`.

## 1. What the server computes today (source of truth)

| Output the app consumes | Server code | Where the logic lives |
|---|---|---|
| Trips + stops (`GET /trips`, trip rows: `started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps, mode, speed_source, start/end lat/lon, point_count`) | `backend/internal/trips/segment.go` (`Clean`, `Segment`), `legs.go` (`buildLegs`, `classify`) | Go, pure |
| Driving events (`speeding`, `hard_brake`, `rapid_accel`; `kind, started_at, ended_at, magnitude, lat, lon`) | `backend/internal/trips/events.go` (`DetectEvents`, `attachEvents`) | Go, pure; thresholds from env `DRIVING_*` (defaults 35.76 m/s, 30 s, 3.5, 3.5 m/s^2) |
| `phone_use` events | phone sensor upload (`handlers/trips_sensor.go`); **never derived from GPS** | the phone already produces them (`driving/phone_use_tracker.dart`) |
| Effective events | SQL view `trip_events_effective`: a GPS event is hidden if a sensor event of the same kind starts within 4 s | SQL |
| Driving report (`GET /trips/report`: totals, per member counts, previous period, `days[]`, `recent_trips[]`) | `handlers/trips_report.go`, `trips_report_days.go`, `computeReportPeriod` | **SQL aggregation** + Go glue |
| Weekly summary (`GET /trips/weekly-summary`, `current`/`previous` per member, `safety_score`) and the Sunday push | `handlers/weekly_summary.go` (`weekStats`, `weeklySafetyScore`, `weeklyDue`) | **SQL aggregation** + Go score |

Not present on the server at all: a hard "driving score" other than the weekly `safety_score`; a per-drive score; "places visited"/stay detection beyond the generic `Stop` list (stops are unnamed, no geocoding, no place matching on the server). The `drive`/`week` result bodies sketched in PRIVACY_PROCESSING.md 8.4 (`score`, `places`, `top_places`, `km`, `drive_min`) therefore have no server definition to reproduce; this spike pins what exists (see 5).

### Algorithm summary (all thresholds pinned in `processing_params.dart`)

* **Clean**: drop invalid positions (NaN, out of range, exactly 0,0), `accuracy > 100 m`, duplicate and out-of-order timestamps (never re-sorted), and "teleports" (implied speed > 90 m/s within a 10 min gap; the third consecutive teleport re-anchors).
* **Segment**: a stop is a dwell of at least 3 min inside `max(50 m, accuracy)` of an anchor fix. Departure needs two consecutive fixes outside the radius with implied speed of at least 1 m/s, then walks back to the last still-looking fix. A trip ends when the device stays inside the radius of a candidate fix for 3 min, or at a gap over 10 min. Movement under 250 m or 2 min is not a trip. In-progress trips are held back (`FinalizeOpen=false`) or closed (`true`).
* **Legs**: per step speed is the device speed (capped at 90) if reported else haversine/dt. Steps under 5 m (or jitter under 20 m while the device reports below 1 m/s) add no distance. Steps are labelled fast (>= 4.5 m/s), slow (>= 1), still; legs shorter than 2 min or 150 m merge into a neighbour; mode from the 90th percentile of moving speeds (>= 5.5 driving, <= 2.5 walking, else other).
* **Events** (driving legs only): speeding = fixes above the limit for >= 30 s (gaps over 15 s split episodes); hard brake / rapid accel = acceleration between fixes 0.5 to 4 s apart, both accuracy <= 30 m, magnitude >= threshold and <= 12 m/s^2 (larger is a GPS jump), the vehicle at >= 5 m/s before braking / after accelerating; adjacent intervals of one kind merge.
* **Weekly**: stats per member over `[from,to)` on `started_at`: driving trips only (count, sum distance, sum duration, max of `max_speed_mps`), events counted by their own `started_at`. `safety_score = clamp(round(100 - 5 * n / max(km,10) * 100), 0, 100)` with `n = hard_brake + rapid_accel + speeding + phone_use`; absent when no drives; the phone count enters the score even when hidden from the JSON (as on the server). The report period is the local Monday-start week or calendar month in a fixed UTC offset; the Sunday-18:00-UTC "due" week is `weeklyDue`.

## 2. The Dart implementation

| File | Role |
|---|---|
| `processing_params.dart` | `TripParams`, `EventParams`, all constants, `kProcessingAlgorithmVersion = 1` |
| `fix.dart` | `Fix`, `haversine`, `stepSpeed`, streaming `FixCleaner`, RFC 3339 helpers |
| `trip_segmenter.dart` | `TripSegmenter` (streaming), `buildLegs`, `segmentFixes` (batch convenience) |
| `driving_events.dart` | `detectEvents`, `effectiveEvents` (the SQL view rule) |
| `driving_report.dart` | `computeWeekStat`, `weeklySafetyScore`, `computeReportPeriod`, `weeklyDue`, `weeklyMemberJson`, `reportMemberJson` |
| `processing.dart` | barrel |

Output JSON shapes equal the server's field names (`trip` row without `id`/`user_id`, event objects, `weekStat`, report `members[]` element, `days[]`, `recent_trips[]`), so existing models (`trip_report.dart`, `weekly_summary_service.dart`) parse them unchanged. Wrapping them into the sealed `trip`/`drive`/`week` result items is phase 5.

Streaming design: `TripSegmenter` is a resumable state machine that follows the Go control flow step for step (stationary phase, moving phase, one fix of lookahead). `add(fix)` is O(1) amortised except at trip end (builds legs/events once over that trip's fixes). `takeNew()` returns finalized trips/stops. Memory is bounded by the retained fixes: from the start of the current stop through the current trip. A stationary period longer than `maxStopFixes` (2048) is folded into running sums (exact centroid and point count). Deterministic: no clocks, no randomness, no I/O. The caller owns persistence of what it needs to resume (see 6).

## 3. Fidelity

The Go fixtures are produced by running the actual Go `Segment`, `attachEvents`, `DetectEvents`, `weeklySafetyScore`, `computeReportPeriod`, `weeklyDue`. For the SQL aggregations the Go test contains a transcription of the queries (it cannot call SQL without a database); equality with the real SQL is **not** proven by these tests (see 7).

### Matches exactly (asserted)
* Number, order, `mode`, `speed_source`, `point_count`, timestamps (microsecond integers), `open` flag of every trip and stop; event kinds, counts and start/end instants.
* Cleaner statistics (`Used`, `OutOfOrder`, `Duplicate`, `LowAccuracy`, `Teleport`, `InvalidPosition`), `in_progress`, `safe_until`.
* Safety score (all cases), report periods (week and month, offsets -480..+840 min, errors), `weeklyDue`, per-day buckets, recent trips and event counts.
* Chunked streaming with `takeNew()` between fixes equals the batch result; forcing the long-stop fold (`maxStopFixes = 40`) does not change any output.

### Tolerated differences (documented, asserted)
* Floating point: distances, speeds, magnitudes, coordinates compared with `abs <= 1e-6 + 1e-9 * |expected|`. Reason: Go and Dart use different libm implementations of `sin/cos/asin`; observed differences are at the last bits. A threshold comparison that lands exactly on the boundary could in principle flip; none occurred in the fixtures.
* Times: Go keeps nanoseconds, Dart microseconds. Phone fixes are millisecond precision, so no effect.
* The server can hold fixes from several devices of one user and interleave them; a phone only has its own device. That is a difference of input, not of algorithm.
* The server's `trip_events_effective` also honours `dismissed_at` / passenger marks (`trip_events_visible`); the phone has no such state in this spike.

### Differences by design (not reproducible on the phone)
* Server `Params`/`EventParams` env overrides (`DRIVING_*`) are compile-time defaults here; the thresholds actually used must be carried in the result (the server already returns them in `thresholds`).
* The server re-segments with a 10 min overlap watermark and a 20000-point cap per pass; the phone streams. With the same fixes the output is identical, with different batching it is also identical (tested), but a phone that missed fixes while the OS killed it will simply have gaps, as the server would for a device that did not report.
* Only the stationary fold (above 2048 fixes in one stop) can deviate: if the walk-back for a departure needed to go behind the folded region (a sustained >= 1 m/s reported speed inside a 50 m radius for more than 64 fixes). Not observed; documented, not asserted.

## 4. CPU and memory (Dart VM micro-benchmarks only)

**There are no battery measurements in this document, and none were possible.** The numbers below come from `app/test/processing/processing_benchmark_test.dart`, run with `flutter test` (two runs agreed within about 30 percent; figures are from the last run; Dart VM, JIT, x86-64 Linux desktop in a Docker container, shared host with load average above 30, no release/AOT build, no Android/iOS runtime). They bound the *algorithmic* cost per fix. They say nothing about energy: wake-ups, radio, GPS duty cycle, storage writes and sealing cost dominate battery on a phone and were not measured. A mid-range ARM phone is typically several times slower than a desktop core; treat the figures as an order of magnitude, not a prediction.

| Scenario | Fixes | Result |
|---|---|---|
| One week, 2 drives/day at 2 s sampling, 60 s sampling otherwise | 22,260 | 123 ms total for the whole week, mean 5.6 us/fix, p99 5 us/fix, worst single `add` 23.5 ms (the call that closes a trip: builds legs and events for ~900 fixes), peak buffer 1,322 fixes |
| Worst case 1 Hz for 24 h (86,400 fixes, 2 drives) | 86,400 | 32 ms total, 0.38 us/fix, peak buffer 3,369 fixes (a 30 min drive at 1 Hz plus context) |
| Weekly aggregation of 1,000 trips + 3,000 events | n/a | 6.4 ms |
| Resident memory delta during the week run | n/a | about 9.5 MiB (includes the 22k test fixes and JIT), so not a clean measurement of the segmenter |

Reading: processing cost per fix is microseconds, i.e. below the cost of receiving a fix from the OS. Buffered fixes are bounded by the longest stop (folded beyond 2,048) or the longest trip (a 10 h drive at 1 Hz would hold 36,000 fixes, roughly 3 MB). No work is proportional to total history, so the segmenter can run on every fix in the existing background isolate or in batches whenever the app wakes. Events and legs are computed once per trip, not per fix.

## 5. What the phone result items can reproduce, and what they cannot

* `trip`: yes (all server fields). `from`/`to` names and `polyline` are not part of the server trip row either (names come from geocoding, off by default for phone-only members; a polyline needs retention of raw fixes, not done by this code).
* `drive`: events yes (speeding, hard brake, rapid accel from GPS exactly as the server; `phone_use` from the existing sensor stream via `effectiveEvents`). A per-drive `score` and `phone_use_s` have **no server definition**; the only score on the server is the weekly `safety_score` implemented here. Do not invent a per-drive score without an owner decision.
* `week`: `drives, distance_m, duration_s, top_speed_mps, events, safety_score` exact. `trips/km/drive_min` are derived trivially. `places`/`top_places` have no server algorithm (stops are unnamed centroids); the phone could match `ProcessedStop`s to the circle's own places, which is new design, not parity.
* Not computable on a phone: anything needing other members' raw fixes, reverse geocoding, map matching, the Sunday push for a phone that is off.

## 6. Integration notes for phase 5

* Persist, per device, only the unfinished state: the segmenter has no serialization yet. The simplest safe resume, same as the server's watermark, is to keep the raw fixes from the start of the last finalized stop (`SegmentResult.safeUntilUs`, minus ~10 min) and replay them into a fresh `TripSegmenter`; replay is deterministic. A snapshot/restore API is left out on purpose to avoid a second source of bugs.
* Feed it the same fixes that are sealed and uploaded (the chunk the phone already holds), time-ordered; out-of-order fixes are rejected exactly as on the server.
* Run in the background isolate; hand `takeNew()` output to the result-item sealing code. Result items are idempotent per trip `started_at` (the server upserts on `(user_id, started_at)`): newest wins.
* Emit a result item only when `takeNew()` returns something; one upload per trip and one per week, as 8.4 assumed.

## 7. Unverified, and device measurements the owner must do

Not verified here:
* The SQL aggregations were transcribed into Go for the fixtures; equivalence to the live SQL on Timescale/Postgres was not run (no database was started). A one-off check against a seeded database is recommended before relying on report parity.
* `trip_events_visible` / dismissed events and passenger marks are not modelled.
* Behaviour on real tracks (the fixtures are synthetic, deterministic scenarios: commute with hard brake / rapid accel / speeding, derived speed, walking, walk-drive-walk, GPS garbage, gaps, in-progress, two drives with a pause, stop-and-go, 12 h stationary, jitter then drive, 30 s sparse sampling). The server's own tests use the same style. Recorded real tracks, once the owner has exported some, should be added as fixtures with the Go generator.
* ARM/AOT performance and anything about battery, thermal state, background execution limits.

Device measurements the owner must do (mid-range Android and an iPhone, release builds, screen off, normal use for at least 24 h each, paired with a control phone running the same app with processing disabled):
1. Battery drain per hour and per day with processing on vs off (Android `dumpsys batterystats` / Battery Historian; iOS Xcode Energy gauge or MetricKit), for a typical day (2 drives) and a heavy day (4 h driving at 1 Hz).
2. CPU time of the background isolate per fix and per closed trip (AOT release, `Timeline`/`dart:developer` markers), and peak RSS during a 10 h drive at 1 Hz.
3. Wake-up count and whether iOS suspends the isolate between fixes (does the segmenter see every fix, or does `TripSegmenter` get bursts after resume?). The algorithm is burst-safe; only completeness of fixes matters.
4. Fix density the platform really delivers when moving and when still (the events need 0.5 to 4 s spacing; at the app's usual 10 to 60 s spacing hard-brake/accel events are under-counted, same as the server, see `docs/driving.md`).
5. Write amplification: size and frequency of result uploads and of the persisted replay window.
6. Compare phone-produced trips with the server's for the same real day on a server-assisted test member (both lanes active) and file the differences.

## 8. How to regenerate / run

```
# Go: regenerate shared fixtures (only when the Go algorithm intentionally changes)
cd backend && UPDATE_PROCESSING_FIXTURES=1 go test ./internal/trips ./internal/handlers -run 'TestProcessing'
# Go: verify committed fixtures are current (runs in normal CI)
cd backend && go test ./internal/trips ./internal/handlers -run 'TestProcessing'
# Dart
cd app && flutter analyze lib/services/processing test/processing && flutter test test/processing
```

A change to any threshold or branch in `backend/internal/trips` fails the Go fixture test (stale file) until the fixtures are regenerated, which in turn fails the Dart tests until the port is updated: that is the drift guard.
