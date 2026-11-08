# Optimisation architecture

Principles, per-platform budgets, the reference architecture for adaptive background tracking, the watch and server architectures, and the measurement plan that keeps Orbitly fast and light on battery from v1.0 on.

Status: architecture decision for the v1.0 release train (November 2026). The work items derived from it live in the
[Optimisation backlog](OPTIMIZATION_BACKLOG.md); the sourced findings behind every number are in the
[Research notes](RESEARCH_NOTES_PERFORMANCE.md). Earlier, narrower performance work is documented in
[Performance](../performance.md) (UI rebuilds, request counts), [API efficiency](../developers/api-efficiency.md) (wire
format) and [Performance and memory on low-RAM phones](../developers/performance-low-memory.md) (device tiers).

Nothing on this page was measured on a phone or a watch while writing it. The audit below cites code; the "Measured
baselines" section lists what ran on the build host and what still has to run on hardware.

## 1. Principles

1. **The radio and the GPS chip are the battery.** CPU time matters on the watch and for smoothness, but on the phone
   the day's drain is decided by how many seconds GPS is powered and how many times the modem leaves idle. Every
   design question is first "does this wake the radio or keep GPS on?".
2. **Events are the clock, not timers.** Activity-recognition transitions, OS geofence exits, visits and the server's
   `live` flag decide when to sample and send. Periodic timers are the fallback, never the main path, and each one
   must have a stated reason and period on this page or in the backlog.
3. **Send changes, not samples.** A viewer needs a new position when it moved on their screen; a watch needs a new
   snapshot when a rendered field changed; the server needs a point when it adds information to the track. Identical
   or sub-threshold updates are dropped at the source.
4. **Batch when nobody is watching, stream when someone is.** The server already tells the phone whether a member is
   being watched (`"live": true` on `POST /locations`). Live means immediate 1 Hz delivery; not live means the same GPS
   quality stored on the phone and uploaded in one request per minute.
5. **The watch renders, the phone thinks.** No network, no GPS, no crypto on either watch. The phone computes
   everything the watch shows and sends the smallest readable snapshot, at a cadence the watch asked for.
6. **Small servers are the target.** The reference deployment is 2 vCPU and 2-4 GB RAM shared between the API and
   Postgres/Timescale. Per-fix server work is a budget (statements, pool checkouts, fsyncs), not an afterthought.
7. **Budgets are measured, not believed.** A budget without a script or a dashboard that reports it does not exist.
   Every budget below names how it is measured.
8. **Cut before you optimise.** When a feature's cost is out of proportion to what families get from it, the
   recommendation is to remove or gate it, and this page says so.

## 2. Target budgets

Targets are for release builds on the named reference devices. "Gate" is what fails CI or blocks a release; "target"
is where we want to be; "store" is the threshold at which Google Play or App Store Connect flags the app.

### Phone app (Flutter, Android and iOS)

| Budget | Target | Gate | Store threshold | Measured by |
|---|---|---|---|---|
| Cold start, process start to first frame (TTID) | <= 1.5 s mid-range Android (Pixel 6a class), <= 2.5 s on a 3 GB phone, <= 0.4 s to first frame on iPhone 12 | median > 2.0 s on the reference phone | Android: 5 s; iOS: Organizer launch p90 | `scripts/perf/startup-time.sh` (adb `am start -W`), hidden Performance screen "startup" line, Xcode Organizer |
| Time to usable map (cached members drawn) | <= 2.5 s | none yet | Android `reportFullyDrawn` (not wired) | Performance screen startup steps |
| Frame build time while panning with 6 members | p90 <= 8 ms, p99 <= 16 ms | > 15% regression in `PERFMETRIC` rebuild counts | > 50% slow frames or > 0.1% frozen frames (> 700 ms) | Performance screen, `flutter test` PERFMETRIC lines, `dumpsys gfxinfo` |
| Janky frames at the display's refresh rate | <= 1% on the 60 Hz budget, <= 5% at 120 Hz | none yet | as above | Performance screen "janky frames" |
| Foreground RAM (PSS) | <= 150 MB standard tier, <= 110 MB lite tier, <= 90 MB when backgrounded under the location service | none yet | Play memory vitals from Feb 2027 (1 GB background on the 4 GB tier) | `adb shell dumpsys meminfo app.openfamily`, DevTools memory view |
| Battery, stationary day (phone at home, app not opened) | <= 3% per 24 h attributable to Orbitly | soak before release | App Review 2.4.2 ("rapidly drain battery") | 8 h `batterystats` soak, Settings > Battery, iOS Organizer background battery |
| Battery, mixed day (1 h driving, 1 h walking, 22 h still) | <= 8% per 24 h; driving <= 5% per hour | soak before release | same | same |
| Data, background, per day (mixed day) | <= 10 MB | none yet | 50 MB/day (Play vital) | Performance screen HTTP table, Android data usage per app |
| Requests per hour, driving, nobody watching | <= 90 (one batch per minute plus heartbeats) | PERFMETRIC request-count tests | none | Performance screen HTTP table |
| Wakeups (AlarmManager) per hour | <= 6 | none | > 10/h (Play vital) | `dumpsys batterystats` alarms |
| Partial wake locks | only the location service's 30 s per-update lock | none | 2 h/24 h background (location-tagged locks exempt) | `dumpsys batterystats` wakelocks |
| APK download size, arm64 release | <= 32 MB; combined arm+arm64 <= 55 MB | +5% over `scripts/apk-size-baseline.txt` | 200 MB warning | `scripts/apk-size-budget.sh`, `scripts/perf/apk-size-report.sh` |
| JSON decode on the UI isolate | no payload over 128 KB decoded inline | `test/perf` | none | existing `compute()` threshold in `api_client.dart` |

RAM tiers (existing, `app/lib/services/perf/device_tier.dart`): lite below 3.5 GiB or `isLowRamDevice`, standard below
5.3 GiB, full above. The tiers size the image cache (24 / 48 / 100 MB), history points (500 / 2000 / 6000 per member)
and tile caches. Section 4 adds "raster tile mode on lite" to that list.

### Background tracking (both platforms)

| Budget | Target | Measured by |
|---|---|---|
| GPS-on time while stationary | 0 s per hour on iOS (accuracy dropped to 3 km, exit region armed), one balanced fix per 15 min on Android | iOS Energy gauge "Location" row; Android `dumpsys location` |
| Fixes while driving | 1 Hz GPS (needed for trips and driving events), uploaded live only when watched | Performance screen "location reporting" line |
| Upload requests while driving, not watched | 1 batch per 60 s | same |
| Upload requests while stationary | 0 (heartbeat only when no report in the last 10 min) | same |
| Position error accepted for the stationary tier | 150 m (exit geofence radius) | design constant |
| Time from "started moving" to first live fix | <= 60 s on Android (activity transition), <= 5 min on iOS (region exit or visit) | manual drive test |

### Wear OS and Apple Watch

| Budget | Target | Measured by |
|---|---|---|
| Snapshots per hour, watch app not in the foreground | <= 12 when the family is idle, <= 60 while someone drives | `adb shell dumpsys activity service WearableService` counters; phone-side counter on the Performance screen (to add) |
| Snapshots per hour, watch app in the foreground | <= 720 (one per 5 s) | same |
| Snapshot size | <= 2 KB for 3 members, <= 7 KB at the 15-member cap | `watch_snapshot.dart` size test |
| Tile and complication refresh requests | only when the rendered "nearest member / age bucket / unread" key changed, at most 1 per minute | Wear logcat |
| Watch cold start to first list | <= 1.0 s on Galaxy Watch Ultra (release build, baseline profile applied) | Macrobenchmark or stopwatch on device |
| Watch frame overrun | p90 <= 0 ms on `ScalingLazyColumn` scroll | JankStats / Macrobenchmark `FrameTimingMetric` |
| Watch battery | not visible in Settings > Battery (< 1% per hour) | Settings > Battery on the watch over 8 h |
| Watch RAM (Apple) | <= 25 MB | `os_proc_available_memory`, Xcode memory gauge |
| What the watch never does | network, GPS, crypto, timers under 60 s, Data Layer pings | code review (section 5) |

### Server (Go + Postgres/Timescale, 2 vCPU, 2-4 GB)

| Budget | Target | Measured by |
|---|---|---|
| `POST /locations` handler + SQL, moving fix | p95 <= 10 ms with fsync on, <= 3 ms with `synchronous_commit=off` | `BenchmarkIngestMoving` (`backend/internal/handlers/live_test.go`), `scripts/perf/ingest-bench.sh` |
| SQL statements per moving fix | <= 8 on the request path (today 16-28 including geofences) | code review of `location.go`, `pg_stat_statements` |
| Pool checkouts per authenticated request | 1 | code review of middleware |
| `POST /locations/batch`, per point | <= 0.2 ms | `BenchmarkIngestBatch100/500` |
| `GET /family/members` | p95 <= 10 ms with 10 members and 3 circles; 304 answered with one query | `perf_endpoints_test.go` (`OF_PERF=1`) |
| WebSocket frames per stored fix per viewer | 1 (today up to one per shared circle) | WS counters on the Performance screen |
| Keepalives per idle socket | 1 every 60-90 s (today 2 every 30 s) | packet capture or server logs |
| Trips segmentation, one day of one user | <= 5 ms | `BenchmarkSegmentDay` (`backend/internal/trips/bench_test.go`) |
| API container | `GOMEMLIMIT` set, no OOM kills in a week | `docker stats`, journal |
| Postgres | tuned for the container limit (`shared_buffers` ~25% of its RAM) | `SHOW shared_buffers` |

### Admin web

| Budget | Target | Measured by |
|---|---|---|
| Shell JavaScript (gzip) | <= 250 KB; map chunk loaded lazily | Vite build output, `size-limit` |
| Lighthouse performance | >= 0.9 (median of 3) | Lighthouse CI |
| Polling while a page is hidden | none | `document.hidden` checks |

## 3. Where we stand (audit summary with evidence)

The phone's reporting policy is already adaptive and well tested in Dart (`app/lib/services/tracking_cadence.dart`:
driving 1 Hz, walking 5 s, stationary foreground 10 m filter, stationary background 60 s, idle 3 min after 10 min
still, low-battery back-offs; `app/lib/services/location_reporter.dart` and `background_location_service.dart` apply
it). The server has a stationary-dedup path, store-and-forward with a batch endpoint, gzip, ETag and compact views
(v0.25). The UI work in [Performance](../performance.md) holds up in code. The gaps are in what the OS is asked for,
in how often the radio is used, and in the watch cadence:

| Area | Finding | Evidence |
|---|---|---|
| Background upload | Every accepted fix is one `POST /locations`; the outbox and the batch endpoint are used only after a failure. At 1 Hz driving that is 3,600 requests per hour whether or not anyone is watching. | `app/lib/services/background_location_service.dart:239-258`, `location_reporter.dart:435-466` |
| Background HTTP | The background isolate uses the top-level `http.post`, which opens and closes a client per call: a new TCP and TLS handshake per fix. The foreground `ApiClient` reuses one client. | `background_location_service.dart:482-495`; `api_client.dart:910-933` |
| Android location request | `interval = fastestInterval = maxWaitTime`, so the fused provider never batches; every fix wakes the Dart isolate and takes a 30 s partial wake lock. | `app/packages/background_locator_2/android/.../provider/GoogleLocationProviderClient.kt:27-35`, `IsolateHolderService.kt:30,175-185` |
| Android stationary | Activity recognition drops to one balanced fix per 15 min when STILL (good), but only on API 29+ with the permission granted; otherwise the Dart profile asks for high-accuracy GPS every 60 s all day. | `ActivityTransitionsManager.kt:36`, `IsolateHolderService.kt:450-460,497-510`; `tracking_cadence.dart:33-34` |
| Heartbeat alarm | An inexact 10-minute wake-up alarm posts a heartbeat unconditionally, even when a fix was posted seconds ago. 6 wakeups per hour against a Play threshold of 10. | `HeartbeatScheduler.kt:30-47`; `background_location_service.dart:60-81` |
| iOS background | `startUpdatingLocation` with the best accuracy and a 50 m filter, `pausesLocationUpdatesAutomatically = NO`, forever. The adaptive cadence (`updateLocationRequest`) is Android-only; iOS never lowers accuracy while still. The exit region is armed only at termination. | `app/packages/background_locator_2/ios/Classes/BackgroundLocatorPlugin.m:157,196-220,84-95`; the method is absent from `ios/` |
| Geofencing | Place arrivals are computed server-side on every ingest (standard circles) and on the phone per fix (private circles). No OS geofence is used anywhere, so a parked phone must keep sampling to notice leaving. | `backend/internal/handlers/geofence_eval.go:93-162`; `app/lib/services/e2ee/private_runtime.dart:669` |
| E2EE per fix | Sealing is cheap, but each private circle writes the queue, a timestamp, the chunker and history to `SharedPreferences` per fix (whole-file rewrites) before the batched, jittered upload. | `private_runtime.dart:648-681`; `PrefsChannelKv` at `:42-85` |
| Server per fix | A moving fix costs 16-28 SQL statements across 4 or more pool checkouts: token-version lookup, circle modes, the ingest transaction (6 round trips, 3 index writes), broadcast lookup, and a geofence pass with its own transaction per candidate. Every commit fsyncs. | `backend/internal/middleware/ingest_key.go:125-200`, `handlers/location.go:112-267`, `geofence_eval.go:93-433`; migrations `000001`, `000025` |
| Server fan-out | One frame per viewer per fix, duplicated per shared circle; two keepalives (server ping and client JSON ping, both 30 s); per-socket revalidation every 30 s with 2 queries. | `handlers/hub.go:19-84,550-576`, `handlers/ws.go:240-307` |
| Watch cadence | The 5 s throttle is real, but the content hash includes a millisecond timestamp and the formatted status line, so a snapshot goes out on nearly every roster frame, always `setUrgent()`, and each one rewrites prefs and requests a tile and complication refresh on the watch. The phone also polls alerts and sharing state over REST every minute for the watch. | `app/lib/services/watch/watch_snapshot.dart:141-147,246-249`, `watch_bridge.dart:245-274,493-526`, `WatchBridgePlugin.kt:141-147`, `wear/.../SnapshotRepository.kt:43-88` |
| Watch link state | The phone's manifest only registers `MESSAGE_RECEIVED`; peer connect/disconnect is effectively never delivered, so publishing continues up to 10 min after the watch is gone and the first snapshot after reconnect can be 10 min late. | `app/android/app/src/main/AndroidManifest.xml:143-145`, `WatchListenerService.kt:34-50` |
| Phone startup | The session gate awaits 5-6 serial Keystore operations and a network-first `/config` fetch (4 s timeout) before the shell appears; the cached config is not applied on timeout. | `app/lib/main.dart:249-260,288-318`, `services/offline/offline_cache.dart:127-146` |
| Map rendering | Vector tiles are rendered on every tier; the motion ticker runs at the display rate (120 Hz on the Fold 4) while a member drives; no per-marker `RepaintBoundary` around blurred shadows. | `widgets/openfamily_map_layers.dart:91-106`, `screens/map_screen.dart:239,333-339,1441-1445`, `member_avatar_bubble.dart:253-255` |
| Idle timers | `CrashWatcher` reads two prefs every 3 s for the process lifetime; `FamilyService` keeps the socket and its two 30 s timers running while backgrounded. | `services/driving/crash_watcher.dart:25-38`, `services/family_service.dart:417,476-477` |
| APK | Combined APK 47.8 MB (arm64 libapp.so 11.3 MB, libflutter.so 11.2 MB, dex 4.7 MB). The size budget never fails: no baseline file and the CI step is wrapped in `|| echo`. ProGuard keeps whole packages. | `scripts/perf/apk-size-report.sh` output below; `.github/workflows/apk.yml:164`; `app/android/app/proguard-rules.pro` |
| Admin web | Two map engines stacked (leaflet + maplibre-gl + glue) in a 1.06 MB chunk; 485 KB shell; polls at 2.5 s, 5 s and 30 s regardless of visibility. | `backend/web/dist`, `web/src/pages/BackupsCard.tsx:59`, `ServerSetupCard.tsx:211`, `SystemPage.tsx:66` |

## 4. Reference architecture: adaptive background tracking

### States and signals

One state machine per device, in the background isolate on Android and in the native plugin on iOS, fed by OS signals
first and GPS speed second:

| State | Enter on | Exit on | GPS request | Upload |
|---|---|---|---|---|
| **Still** (anchored) | Activity STILL (Android) or no displacement > 60 m for 10 min; iOS: `isStationary`, visit arrival, or 10 min inside the filter | Activity EXIT STILL / IN_VEHICLE / WALKING; exit of the 150 m anchor region; iOS visit departure or region exit | Android: balanced, 15 min, no filter (today). iOS: accuracy 3 km, filter 200 m (to do). Later: no GPS at all, exit geofence only | none; heartbeat only when no report in the last 10 min |
| **Walking** | smoothed speed >= 0.8 m/s or WALKING/RUNNING/ON_BICYCLE | speed < 0.4 m/s for 30 s | high accuracy, 5 s (15 s low battery), `maxWaitTime` 60 s when not live | batch every 60 s when not live; per fix when live |
| **Driving** | smoothed speed >= 3 m/s for 2 fixes or one fix >= 8 m/s or IN_VEHICLE | speed < 1 m/s for 60 s | high accuracy, 1 s (5 s low battery); `maxWaitTime` 60 s when not live | batch every 60 s when not live; per fix (<= 1 Hz) when live |
| **Live** (someone is watching, a boost or SOS) | `"live": true` on the last upload, `/locations/watch` from a viewer, SOS | 10 s after the last live flag (boost TTL), SOS end | the moving state's request with `maxWaitTime = interval` | per fix, immediately |

The tiers, speeds and hold times already exist in `tracking_cadence.dart`; the architecture change is the **upload
column** and the **iOS GPS column**. "Live" already exists as `LiveBoost`; it becomes the switch between streaming and
batching rather than only a sampling boost.

### Upload pipeline

1. A fix passes `FixQualityFilter` and feeds the cadence (unchanged).
2. **Live:** `POST /locations` immediately over a persistent `http.Client` held by the isolate (one TLS session,
   HTTP keep-alive). The response's `live` flag extends the live window.
3. **Not live:** the fix goes to the outbox (today's `LocationOutbox`, moved from prefs-JSON to an append file or
   SQLite as part of the change) and a 60 s flush timer, started by the first queued fix, drains it with
   `POST /locations/batch` (<= 100 points). The batch response carries the same `live` flag; `true` switches to
   streaming at once and triggers an immediate post of the newest fix.
4. **Still:** nothing is queued (the server's stationary dedup already stores no row). The heartbeat alarm fires every
   10 min but posts only if no upload happened in the last 10 min.
5. Failures keep today's semantics (outbox retry with strikes, 4xx drop, 401 pause).

What this buys, per hour of driving with nobody watching: 3,600 requests become about 60, each 100 points; the
server's per-fix work (section 6) is replaced by two pipelined statements per point; the modem stays in idle between
batches; TLS handshakes drop from 3,600 to a handful. The server-side effect on a 2 vCPU box with six drivers is from
100-170 statements per second to under 15. The GPS cost is unchanged while driving (1 Hz is needed for trip quality and
driving events) and that is intended: the GPS chip at 1 Hz is roughly a fixed cost once it is on; the radio was the
variable one.

### iOS specifics

The native plugin needs the same `updateLocationRequest` the Android side has, mapping the Dart profile to
`desiredAccuracy` and `distanceFilter`, plus two things Core Location gives for free: `activityType =
.otherNavigation` when driving (better pause heuristics) and, in the Still state, `kCLLocationAccuracyThreeKilometers`
with a 200 m filter and a 150 m exit-only `CLCircularRegion` around the anchor (the plugin already has
`observeRegionForLocation`, used only at termination). Significant-change monitoring stays on as the relaunch safety
net. Apple's own guidance is exactly this: drop to 3 km accuracy in the background rather than pause, and prefer region
and visit monitoring to continuous updates. Expected effect: GPS-on time while still goes from 100% to near zero, which
on iOS is the difference between "Orbitly is the top item in Settings > Battery" and not being there.

### Later: OS geofence as the wake signal

The end state for Still is "no GPS at all": arm a 150 m exit geofence (Android Geofencing API, 5 min responsiveness;
iOS `CLMonitor` circular condition) around the anchor and stop location updates. Leaving the region restarts the
walking tier. Google documents 2-6 min exit latency and Apple 3-5 min, so the first fix after leaving home arrives a few
minutes later than today; the family sees "left home" at the same time either way, because the server's arrival and
departure events come from places, not from the stationary pings. This is marked LATER because it needs a device
test matrix (OEM geofence behaviour varies) and because the Android 15-min balanced profile already gets most of the
win.

## 5. Watch architecture

**What the watch shows.** The roster (name, initials, colour, state, place or distance, age), unread count, sharing
state, the last command result, alerts, SOS and check-in buttons, a compass arrow. Nothing else.

**What the watch never does.** Network, GPS or any location permission, crypto, timers under 60 s, Data Layer or
WatchConnectivity "are you there" pings, work when the screen is off beyond applying a snapshot, AlarmManager or
WorkManager under 2 h, `keepScreenOn`, an Ongoing Activity for passive status.

**How often it updates.** Three cadences decided by the phone:

| Watch state | How the phone knows | Snapshot cadence | Urgent |
|---|---|---|---|
| App in the foreground | `watching` command on resume and every 30 s (same TTL pattern as `/locations/watch`) | at most every 5 s, only when the projected content changed | yes |
| App in the background, tile or complication installed | default | at most every 60 s, only when the projected content changed; keep-alive every 10 min | only for alerts, command results, unread or sharing changes |
| No watch connected | capability change on Android, `isReachable`/`isPaired` on iOS | nothing is built or sent | n/a |

**Projected content.** The content hash covers only what changes the rendering: position snapped to about 50 m, the
age bucketed to the minute, place and state, battery to 5%, unread, sharing, alerts, last command. Relative times are
not formatted on the phone: the snapshot carries timestamps and both watches format ages locally, so a minute ticking
over does not produce a snapshot. Distance and bearing use the `you` member's position already in the snapshot, as the
Apple app does today; the Wear app's own `getLastKnownLocation` and its location permission go away.

**On the watch.** The listener parses, stores the content once, and asks for a tile or complication refresh only when a
small surface key (nearest member id, age bucket, unread, sharing) changed or 60 s passed. The UI collects a content
flow (`distinctUntilChanged`) separate from the timestamp, keys list items by member id, and drives age text from a 60 s
ticker. Both watch modules ship a baseline profile and are judged only on release builds on the device (Google's and
Samsung's guidance both say debug-build jank on Compose for Wear is expected and meaningless).

**Apple specifics.** `updateApplicationContext` stays the transport (latest-value-wins is the right semantics);
`sendMessage` only from the watch on user action; `transferUserInfo` reserved for SOS and check-in results that must not
be lost. No complication for v1 (its 50-transfers-a-day budget needs its own design); no background refresh tasks.

## 6. Server ingest and fan-out architecture

**Ingest.** The batch endpoint becomes the common case (section 4), so its path is the one to make cheap: one
dedupe query, one `INSERT ... SELECT unnest(...)` for all points, one `member_positions` upsert for the newest point,
one `devices.last_seen` update, in one transaction with `SET LOCAL synchronous_commit = off` (losing up to a second of
location rows on a crash is acceptable; account and billing paths keep full durability). The single-fix path keeps its
transaction but drops to one pool checkout: token version and circle modes come from a 5-10 s in-process cache that
the mutation paths invalidate (they run in the same process), the body is decoded once, and the geofence pass is
skipped when the user has no enabled geofences and otherwise does one `UPDATE ... RETURNING` per candidate instead of a
four-statement transaction. `locations` keeps one btree `(device_id, ts)` (the unique index) and drops the duplicate
btree; the GIST index on `geom` is dropped after a grep confirms no spatial predicate reads it. Compression and
retention stay as they are (7-day chunks, compress after 7 days, 90-day retention).

**Fan-out.** One `location` frame per stored fix per viewer socket, carrying `circle_ids` for clients subscribed to
"all" (today they get one frame per shared circle); server-side coalescing per (socket, subject) to 250 ms only matters
for SOS at 2 Hz and is not needed for v1. One keepalive: the client's JSON ping every 60 s with a 150 s server read
deadline; the server's protocol ping goes. Per-socket revalidation moves from 30 s to 5 min (logout and password change
already disconnect directly). Writes get a 10 s deadline so a half-open phone cannot block a writer goroutine.

**Push.** Commands (`live_boost`, location requests) go over the live socket when the device is connected and fall
back to FCM/APNs/UnifiedPush only otherwise, so a phone holds one long-lived connection, not a WebSocket plus an SSE
stream. Alerts keep `apns-priority 10`; commands keep `background` + priority 5 and gain `apns-collapse-id` and a ntfy
`Priority: low` so they coalesce.

**Trips.** The worker stays periodic (5 min, 4 users at a time) and off the ingest path. The report's N+1 (re-reading
raw points per driving trip) is removed by storing speed-event counts on the trip row at segmentation time. The
segmenter itself is fast (see baselines).

**Runtime.** `GOMEMLIMIT` at 90% of the API container's memory limit, `cpus: 2.0` for the API, pgx `MinConns = 3`,
and explicit Postgres settings sized to the Postgres container (`shared_buffers` 256 MB, `effective_cache_size` 640 MB,
`work_mem` 8 MB, `max_connections` 60 for a 1 GB container), because the image's auto-tuning reads host RAM, not the
cgroup.

## 7. Phone app: startup, rendering, memory

- **Startup:** the gate awaits only what the first screen needs (session check and the cached config); housekeeping
  and the `/config` revalidation run after the first frame, and the cached config is applied immediately. `reportFullyDrawn`
  is called when the map has drawn cached members, so Play's TTFD matches what users feel.
- **Rendering:** the lite tier renders vector tiles in raster mode; the motion ticker is capped at 60 Hz and stops
  when every animating pin moves less than half a pixel per frame; bubbles and clusters sit in their own
  `RepaintBoundary`; the draggable sheet body too. Impeller stays on (it is the only engine on iOS and the default on
  Android); Mali and MediaTek 3-4 GB devices get a release-build smoke test before launch because that is where the
  known Impeller regressions live.
- **Idle cost:** no polling timers in the UI isolate while the app is backgrounded: `CrashWatcher` becomes
  event-driven and `FamilyService` pauses its socket and staleness timer on `AppLifecycleState.paused` (alerts and chat
  are covered by push by design; the resume path already refetches members).
- **Memory:** the tiers stay; the vector-tile memory cache and the map style cache register as memory-pressure
  trimmers; `leak_tracker` guards the map and member widgets in tests.
- **Size:** the baseline is recorded and the budget step fails the build; ProGuard keeps are narrowed to the classes
  that are reflected on (later, with a device test).
- **Large screens:** one breakpoint helper fed by one width source replaces the three disagreeing definitions (shell
  rail at 840 dp, two-pane at 720 dp, camera offsets at 720 dp on window size). The specific Fold 4 rendering bug is
  handled by its own workstream; this is the structural follow-up.

## 8. Measurement plan and CI gates

**Already in place:** the hidden Performance screen (frames, rebuilds, HTTP, WebSocket, cadence profile, fixes per
minute), `PERFMETRIC` tests under `app/test/perf`, `BenchmarkIngestMoving`, `perf_endpoints_test.go` (`OF_PERF=1`),
`scripts/apk-size-budget.sh` (not enforced), the k6 load script (posts to `/api/locations`, which does not exist;
fix it).

**Added with this page:**

- `backend/internal/trips/bench_test.go`: `BenchmarkSegmentDay` (one realistic day, 5,100 points),
  `BenchmarkSegmentDrive20k` (the 20,000-point `ProcessUser` cap), `BenchmarkDetectEventsDay`, `BenchmarkCleanDay`,
  `BenchmarkCountSpeedEventsPerTrip` (the report N+1 unit), pinned by `TestSynthDayShape`.
- `backend/internal/handlers/ingest_bench_test.go`: `BenchmarkIngestBatch100`, `BenchmarkIngestBatch500`,
  `BenchmarkIngestStationary` next to the existing `BenchmarkIngestMoving`.
- `scripts/perf/ingest-bench.sh`: throwaway TimescaleDB in Docker, migration, both benchmark sets, cleanup.
- `scripts/perf/apk-size-report.sh`: per-component APK breakdown, `--tsv` for trend charts.
- `scripts/perf/startup-time.sh`: N cold starts on a connected device, median and p90, exits non-zero over
  `STARTUP_BUDGET_MS` (default 2000), exits 2 when no device is attached so CI can skip it.

**Gates for v1.0 (CI):** APK growth > 5% over the recorded baseline fails; `PERFMETRIC` regressions fail (existing
tests); Go benchmarks run on PRs that touch `handlers/location*.go` or `trips/` and are compared with `benchstat`
(10 counts; a p < 0.05 regression over 10% fails); docs, license and rebrand checks as today.

**Gates for v1.0 (release checklist, on hardware, recorded in the release notes):** `startup-time.sh` on the Fold 4
and a 3 GB phone; the Performance screen report after a 10-minute drive with 3+ members (jank %, p99, WS per minute,
fixes per minute); an 8-hour `batterystats` soak with the phone stationary and another with a 1-hour drive; Settings >
Battery on the Galaxy Watch Ultra and the Apple Watch after a day; `dumpsys activity service WearableService` snapshot
counters; Xcode Organizer launch time and hang rate on the oldest supported iPhone; Play pre-launch report clean.

**Weekly after launch:** Play vitals (crash < 0.5%, ANR < 0.2%, wakeups, wake locks, background network, slow frames
per device model, with the Fold 4 and Galaxy A-series watched specifically), App Store Connect power and performance
metrics, Organizer regression notifications on.

**Later:** `flutter drive --profile` timeline summaries on a self-hosted device (p90 build <= 8 ms, p99 <= 16 ms,
missed budget <= 1%); a Macrobenchmark module for the Wear app; Lighthouse CI and `size-limit` for the admin web;
Power Profiler rails on a Pixel 6+ to A/B tracking intervals.

## 9. Measured baselines

Build host only (16-core x86 server, shared), no devices. Re-run the scripts above on hardware before quoting these
numbers anywhere user-facing.

**APK** (`scripts/perf/apk-size-report.sh` on the current combined release APK):

| Component | Size |
|---|---|
| Combined APK file (arm + arm64 + x86_64 webcrypto) | 47.8 MB |
| `lib/arm64-v8a` total | 23.0 MB (libapp.so 11.3 MB, libflutter.so 11.2 MB) |
| `lib/armeabi-v7a` total | 21.1 MB (libapp.so 12.5 MB, libflutter.so 8.2 MB) |
| `classes*.dex` | 4.7 MB |
| Flutter assets | 0.4 MB |
| Resources | 0.8 MB |

The Dart AOT snapshot is the largest controllable item; the engine is fixed. An arm64-only APK is about 29 MB
uncompressed, which is where the 32 MB budget comes from.

**Server benchmarks** (`go test -bench`, Go 1.27 in Docker, `--cpus=4`; Postgres with `fsync=off` so the ingest numbers
exclude disk latency): see the table below, filled from the runs recorded with this change.

| Benchmark | Result | Notes |
|---|---|---|
| `BenchmarkSegmentDay` | 3.5-4.1 ms/op, 577 KB, 40 allocs | one day, 5,100 points: within the 5 ms budget |
| `BenchmarkSegmentDrive20k` | 13.4-17.0 ms/op, 2.75 MB, 23 allocs | 20,000 points of 1 Hz driving (the `ProcessUser` cap) |
| `BenchmarkDetectEventsDay` | 1.8-2.1 ms/op, 415 KB, 3 allocs | |
| `BenchmarkCleanDay` | 1.5-1.7 ms/op, 369 KB, 1 alloc | |
| `BenchmarkCountSpeedEventsPerTrip` | 0.53-0.56 ms/op, 131 KB | per 30 min driving trip; a 200-trip report spends ~0.1 s CPU here plus one range query per trip (OPT-35) |
| `BenchmarkIngestMoving` | 5.0-9.1 ms/op, 15.6 KB, 195 allocs | one `POST /locations`, handler + SQL, fsync off; 3 runs x 200 |
| `BenchmarkIngestStationary` | 4.2-9.2 ms/op, 14 KB, 157 allocs | dedup path writes no row yet costs as much as a moving fix: the cost is round trips and auxiliary queries, not the insert |
| `BenchmarkIngestBatch100` | 26-39 ms/op for 100 points (0.26-0.39 ms per point) | 15-25x cheaper per point than a single fix |
| `BenchmarkIngestBatch500` | 93-194 ms/op for 500 points (0.19-0.39 ms per point) | the maximum batch |

Reading: with disk latency removed, a single fix still costs 5-9 ms of server time and a batched point 0.2-0.4 ms.
That ratio is the server-side case for section 4 (batch when nobody is watching) and for OPT-16, OPT-19 and OPT-24;
the stationary path's cost is the case for "no network while still". The spread between runs is the shared build host;
use `-count 10` and `benchstat` before quoting a change. The geofence pass runs after the response and is not inside
these numbers.

## 10. Recommended cuts

- **Stop posting every background fix when nobody is watching.** Replaced by the batch pipeline (section 4).
- **Stop the heartbeat POST when a report already went out** in the alarm window; keep the alarm.
- **Stop `setUrgent()` on every watch snapshot**, the watch's own GPS reads, the phone's one-minute REST polling for the
  watch, and tile/complication refreshes per snapshot.
- **Drop one of the two WebSocket keepalives** and lengthen the survivor.
- **Drop the duplicate btree on `locations`** and, after verification, the GIST index.
- **Drop leaflet from the admin web** (one map engine) and lazy-load the heavy pages.
- **Replace `CrashWatcher`'s 3 s disk poll** with an event.
- **Not worth it for v1:** switching the wire format to protobuf or CBOR (gzip JSON is already small and the client
  decode moves off the UI isolate above 128 KB); removing PostGIS (used by places); OS-geofence-only stationary mode
  (LATER, needs a device matrix); `encoding/json/v2` and PGO on the server (2-14% CPU on a server that is not CPU-bound);
  Flutter deferred components (Play-only, we also ship sideloaded APKs); an Impeller opt-out (deprecated, only if a
  specific device crashes); an Apple Watch complication (budget design first).
