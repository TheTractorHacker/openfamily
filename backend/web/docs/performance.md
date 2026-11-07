# Performance

The server is not the bottleneck (`/healthz` ~1.5 ms locally, hot endpoints
below 15 ms p95 on a seeded database; see "Backend"). The work here targets the
phone: rebuild cost, startup, and request count. None of it could be run on a
device while writing it, so this page also describes how to collect real
numbers.

## On-device instrumentation

Open **Settings, tap the "OpenFamily / Version" row 7 times** (each tap within
2 s of the last). The hidden **Performance** screen shows:

- startup: process start to first frame (process age at `main()` from
  `/proc/self/stat`, plus `main()` to first frame) and timed startup steps;
- frame build and raster p50 / p90 / p99, janky-frame percentage against the
  display refresh rate (16.7 ms at 60 Hz, 8.3 ms at 120 Hz), and the 10 slowest
  frames with the screen that was visible (`AppShell:location`, a page class
  name, ...);
- per-screen rebuild counters (`MapScreen`, `LocationTabView`, `PeopleList`,
  `PersonRow`, `MapMarkers`, `MapMarkerLayer`);
- WebSocket frames received / applied / UI updates, total and per minute;
- HTTP requests and latency by endpoint (ring buffer of the last 400).

**Copy report** puts a compact text report on the clipboard; **Reset** clears
the counters. Only a tiny always-on frame summary runs by default (one
`FrameTiming` callback, fixed-size histograms). Rebuilds, HTTP and WebSocket
recorders are off until "Record details" is switched on. Everything is in
memory: nothing is written to disk or sent anywhere. HTTP entries are
`METHOD /normalised/path` only: ids, tokens, queries, bodies and coordinates
never reach the buffer (path segments that are not plain lower-case words
become `:id`).

Code: `app/lib/services/perf/perf_monitor.dart`,
`app/lib/screens/performance_screen.dart`.

### Collecting numbers

1. Install a release or profile build, open the Performance screen, switch on
   "Record details", Reset, then use the app for a few minutes (open the map,
   drag the sheet, switch tabs, open a trip report, let a family member drive).
2. Copy report and send it.
3. Cross-checks without the app:
   - `adb shell dumpsys gfxinfo app.openfamily reset` then use the app, then
     `adb shell dumpsys gfxinfo app.openfamily framestats` (per-frame
     timestamps; "Janky frames" and the 50/90/95/99th percentiles are at the
     top of plain `dumpsys gfxinfo app.openfamily`).
   - Cold start: `adb shell am start -W -n app.openfamily/.MainActivity`
     (TotalTime).
   - Flutter DevTools: `flutter run --profile`, open the Performance tab
     (frame chart, "Track widget rebuilds"), the CPU profiler, and the Network
     tab. Use a profile build, never debug, for timings.

## What changed

| Area | Change |
|---|---|
| Map / sheet | A WebSocket location frame no longer rebuilds `MapScreen`, the tab view, the tile layer or the sheet. The roster is a `ValueNotifier` that only the range circles, the marker layer and the People list listen to. Hidden tabs and covered routes skip those rebuilds (`VisibleValueBuilder`, keyed on `TickerMode`). |
| Burst coalescing | `FamilyService` delivers live frames to the UI at most once per 220 ms (leading edge immediate, trailing delivery with the newest data). Snapshots (REST, `members` frame, circle switch) are never delayed. |
| Markers | Bubble widgets are cached per member instance, so panning only recomputes positions. Tile layer sits in its own `RepaintBoundary` and is a `const` widget. |
| People rows | A row widget is reused while its member and flags are unchanged. |
| Floating buttons | The Check in / SOS / layers row is a `ValueListenableBuilder` child, not rebuilt on every sheet drag frame. |
| Avatars | Decoded at 2x display size with `ResizeImage` (was native size); a cached photo is in the first frame (no initials flash); decode is precached when the bytes land. |
| Shell | Tab bodies are created once; switching tabs no longer rebuilds every visited tab. |
| Startup | `main()` reads theme, map style and server URL in parallel and does not await the system-UI call. The session gate runs housekeeping, the `/config` fetch and the session check together. Push sync and the config refresh start after the first frame. |
| Network | `/config` cached 5 min and single-flighted; places cached 30 s (invalidated on create / update / delete / login / logout, bypassed by the Places screen); roster and places fetched side by side; family name and roster fetched together; the circles screen return no longer fetches `/circles` twice. |
| JSON | Responses of 128 KB or more are decoded with `compute()`. |
| WebSocket | Backoff resets only after a connection survived 10 s (was: on the first frame, so accept-then-drop servers were retried every second); connectivity events are debounced 800 ms. |

Audited and left alone: saveLayer sources (no `BackdropFilter`, `ShaderMask`,
`ColorFiltered`, `ImageFiltered` or `antiAliasWithSaveLayer` anywhere; five
`Opacity` / `AnimatedOpacity` uses that only layer while dimmed or fading,
guarded by `test/perf/save_layer_audit_test.dart`); no `shrinkWrap` lists;
long lists are already lazy; no per-second tickers (labels are clock times);
the vector tile layer stays mounted (dropping it would blank the map on every
return to the Location tab, and while hidden it does no work now) with its
existing 2 concurrent / 10 MB / 50 MB settings and a style future that is only
recreated when the style URL changes.

Considered and not done: showing the shell before the session check finishes.
The check refreshes the token over the network when the 15-minute access token
expired; running that in parallel with the first API calls would race two
refreshes on the same refresh token. It needs the gate's refresh and the 401
refresh unified into one single-flight first.

## Behaviour changes

- `/config` is reused for 5 minutes (was refetched on resume); places for 30 s
  outside the Places screen.
- Live location frames reach the map at most ~4.5 times per second.
- The Driving / Circle tabs still update only on roster snapshots, exactly as
  before (the shared notifier keeps its identity semantics).
- WebSocket backoff reset and connectivity debounce, as above.
- Session gate: legacy cleanup no longer precedes the config fetch and session
  check (they run concurrently).

## Before / after (measured in tests, same harness on `main` and here)

| Proxy | Before | After |
|---|---|---|
| Requests at startup (gate + map + push) | 7 (`/config` x3) | 5 |
| Requests on resume / pull-to-refresh | 3 (members, places, config) | 1 |
| Requests on circle switch | 2 | 1 |
| 20 location frames: tab view rebuilds | 20 | 0 |
| 20 location frames: person rows rebuilt | 200 | 20 |
| 20 location frames: `DsListRow` builds | 220 | 40 |
| 50 frames in 1 s: UI updates | 50 | 6 |
| 20 tab switches (4 tabs visited): body rebuilds | 80 | 0 |
| 30 pan frames, 6 members: bubble rebuilds | 90 | 0 |
| 40 sheet-drag frames: floating buttons rebuilt | 80 | 0 |
| 4000x3000 avatar at 44 dp, 3x: decoded bitmap | 46,875 KB | 204 KB |
| 2.5 MB JSON: longest event-loop gap | 76 ms (sync decode) | 55 ms |
| Hidden Location tab, 20 frames: row rebuilds | not measured on main (it had no hidden-tab guard) | 0 |

The JSON row is a weak result on a loaded x86 host: the gap includes isolate
start-up and result hand-over, so treat the benefit on a phone as unconfirmed
until measured. The numbers come from `flutter test` output lines starting
`PERFMETRIC` (see `test/perf`, `test/services/startup_requests_test.dart`).
Frame times, startup time and jank percentage cannot be measured in tests; use
the Performance screen.

## Backend

`backend/internal/handlers/perf_endpoints_test.go` (opt-in: `OF_PERF=1` and
`TEST_DATABASE_URL`, throwaway database only) seeds 3 users, 20,000 locations,
300 trips, 1,020 trip events and 5 places on TimescaleDB, then times each
endpoint 40 times through the real handlers (handler plus Postgres, no network):

| Endpoint | p50 | p95 |
|---|---|---|
| GET /config | 0.01 ms | 0.04 ms |
| GET /family/members | 2.6 ms | 7.0 ms |
| GET /family/places | 1.0 ms | 1.2 ms |
| GET /trips (30 days, limit 200) | 1.8 ms | 3.1 ms |
| GET /trips/report (week) | 6.4 ms | 9.4 ms |
| GET /trips/report (month) | 7.9 ms | 13.7 ms |
| GET /trips/{id} | 1.6 ms | 4.0 ms |
| POST /locations | 5.3 ms | 10.6 ms |

Everything is far below 100 ms, so no index or migration was added.

## Measure on the phone

See the checklist in the pull-request description; in short: cold start time,
janky % and p99 while dragging the sheet and panning with 3+ members, rebuild
counts and WebSocket UI updates per minute during a drive, and the HTTP table
after launch and after switching circle.
