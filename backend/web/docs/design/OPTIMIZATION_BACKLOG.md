# Optimisation backlog

Prioritised, independently assignable work items that implement the optimisation architecture, each with files, expected win, risk, size, dependencies, a done criterion and a recommended agent tier.

Derived from [Optimisation architecture](OPTIMIZATION_ARCHITECTURE.md) (budgets and design) and the
[Research notes](RESEARCH_NOTES_PERFORMANCE.md) (sources). Ordered within each group by impact on the v1.0 store and
demo quality divided by effort. Sizes: S under half a day, M one to two days, L three days or more. Tiers: **Sonnet**
for mechanical, well-specified changes; **Opus** for concurrency, crypto, native Android/iOS/Kotlin/Swift or SQL with
data-loss risk; **Fable** for architecture-level changes that touch several components. Expected wins are estimates
with the assumption stated; "measured" means the done criterion includes the measurement.

Concurrent workstreams (do not duplicate; build on them): driving dashboard, identity and check-in bugs, Z Fold 4
rendering, Galaxy Watch Ultra Compose performance, store readiness, demo server, CI speed. Items below that border on
those say so.

## MUST for v1.0

### OPT-01 Persistent HTTP client in the background isolate

- **Area:** background tracking (Dart). **Size:** S. **Tier:** Sonnet.
- **Files:** `app/lib/services/background_location_service.dart` (`_post`, `_postLocation`, `_sendLocationBatch`,
  `_report`), `app/lib/services/e2ee/private_runtime.dart` (`IngestKeyChannelApi` also uses top-level `http.post`).
- **Why:** the top-level `http.post` opens and closes a client per call, so every background fix pays a TCP and TLS
  handshake and keeps the modem out of idle longer. The foreground `ApiClient` already shares one client.
- **Expected win:** at 1 Hz driving, 3,600 handshakes per hour become a few reconnects; per-request latency drops by
  one to two round trips (100-300 ms on LTE); less radio-on time. Assumption: server and proxy keep connections alive
  (Caddy does by default).
- **Risk:** low. A stale connection must fall back to a new one (the `http` package does this on `ClientException`;
  add one retry).
- **Dependencies:** none. **Done:** unit test that two sequential posts reuse the same `http.Client` instance; Performance
  screen HTTP p50 for `POST /locations` from the background isolate recorded before and after on a phone.

### OPT-02 iOS: adaptive cadence and a cheap stationary mode in the native plugin

- **Area:** background tracking (iOS native, Objective-C). **Size:** M-L. **Tier:** Opus.
- **Files:** `app/packages/background_locator_2/ios/Classes/BackgroundLocatorPlugin.m`, `Helpers/MethodCallHelper.m`,
  `Globals.m`, `lib/background_locator.dart` (`updateLocationRequest` already sends the method; iOS must handle it),
  `app/lib/services/background_location_service.dart:125-143` (remove the Android-only assumption).
- **Why:** iOS runs `startUpdatingLocation` with best accuracy and `pausesLocationUpdatesAutomatically = NO`
  permanently; nothing lowers accuracy while still. Apple's energy guide says to drop to `kCLLocationAccuracyThreeKilometers`
  in the background and prefer region monitoring. App Review 2.4.2 covers battery drain.
- **Do:** implement `updateLocationRequest` on iOS mapping the profile to `desiredAccuracy`, `distanceFilter` and
  `activityType` (`.otherNavigation` when fast); when the profile is stationary or idle, set 3 km accuracy, a 200 m
  filter, and arm a 150 m exit-only `CLCircularRegion` around the last fix (`observeRegionForLocation` exists); on
  region exit or a visit departure, switch back to the walking profile. Keep significant-change monitoring on.
- **Expected win:** GPS-on time while still from continuous to near zero on iOS; the dominant iOS battery item.
  Assumption: most of a day is still.
- **Risk:** medium: region exits arrive 3-5 min late (Apple), so the first fix after leaving is later than today; the
  Dart cadence must treat the first fix after a region exit as "moving" at once (`driveEnterInstantSpeedMps` covers
  driving; add a walking shortcut).
- **Dependencies:** none. **Done:** compiles in the iOS CI build; a simulator run with a simulated route shows the
  profile switch in logs; a TestFlight day on one iPhone with Settings > Battery screenshot recorded in the release notes.

### OPT-03 Batch uploads when nobody is watching ("live" switches streaming on)

- **Area:** background tracking (Dart) and server contract. **Size:** M. **Tier:** Opus (two isolates, outbox
  consistency, live/not-live race).
- **Files:** `app/lib/services/background_location_service.dart` (`onLocationUpdate`, `_sendAndDrain`),
  `app/lib/services/location_reporter.dart` (`_deliver`), `app/lib/services/location_outbox.dart` (flush timer and a
  cheaper store: an append-only file or `sqflite` instead of a JSON blob in prefs), `app/lib/services/live_boost.dart`,
  `backend/internal/handlers/location_batch.go` (return the same `live` flag as the single endpoint),
  `docs/live-tracking-client.md` (policy table), `app/test/services/*location*`.
- **Why:** every fix is a request today; the batch endpoint is only a failure path. See architecture section 4.
- **Expected win:** requests per hour while driving unwatched 3,600 to about 60; server statements per fix from 16-28
  to 2 pipelined per point; measurable radio idle time; background data per day down by the request overhead (about
  600 bytes of headers per request, 2 MB per driving hour). Assumption: viewers watch for minutes, not hours.
- **Risk:** medium: a viewer opening the map must see fresh data within seconds. The `/locations/watch` call from the
  viewer already sends a `live_boost` push to the subject; the first batch response with `live: true` must trigger an
  immediate post of the newest fix. Test the race where the phone switches from batch to live while a batch is in flight.
- **Dependencies:** OPT-01 (otherwise batch posts also reconnect). **Done:** `PERFMETRIC` request-count tests for a
  simulated 10-minute drive watched and unwatched; `BenchmarkIngestBatch100` per-point cost recorded; server test that
  the batch response carries `live`.

### OPT-04 Heartbeat only when nothing was reported

- **Area:** background tracking (Dart). **Size:** S. **Tier:** Sonnet.
- **Files:** `app/lib/services/background_location_service.dart:60-81` (`onHeartbeatTick`), optionally
  `app/packages/background_locator_2/android/.../HeartbeatScheduler.kt:30` (interval stays 10 min).
- **Why:** the alarm's POST is unconditional; while fixes flow it only adds a request and a radio wake every 10 min.
- **Expected win:** 6 requests per hour removed whenever reports flow; Android vitals wakeups unchanged (the alarm
  still fires; it just does no network).
- **Risk:** none (the server refreshes `last_seen` on every report already).
- **Dependencies:** none. **Done:** unit test with a fake clock: heartbeat skipped when `_lastPostAt` is within 10 min.

### OPT-05 Android: let the fused provider batch when not live

- **Area:** background tracking (Android native, Kotlin). **Size:** S. **Tier:** Opus.
- **Files:** `app/packages/background_locator_2/android/.../provider/GoogleLocationProviderClient.kt:27-35`,
  `provider/LocationRequestOptions.kt`, `IsolateHolderService.kt` (`updateLocationRequest`), `lib/background_locator.dart`
  (`updateLocationRequest` gains `maxWaitMs`), `app/lib/services/background_location_service.dart:125-143`.
- **Why:** `maxWaitTime = interval` disables batching; every fix wakes the Dart isolate and takes a 30 s wake lock.
  Google: set the max update delay "several times larger than the interval".
- **Do:** pass `maxWaitTime = 60 s` for walking and driving profiles when not live (OPT-03's flag), `= interval` when
  live; move from the deprecated `LocationRequest.create()` to `LocationRequest.Builder` with `setMaxUpdateDelayMillis`.
- **Expected win:** isolate wakeups and wake-lock acquisitions while driving unwatched from 3,600 to 60 per hour;
  Dart-side CPU in the background isolate down proportionally.
- **Risk:** low-medium: batched `LocationResult` carries several locations; `LocationParserUtil` must forward all of
  them in order (today it takes the last). Needs `flutter build apk --release` to prove it compiles.
- **Dependencies:** OPT-03 for the flag (can land first with a constant). **Done:** Kotlin unit test for the request
  builder; release APK built; a logcat capture on a phone showing batched results.

### OPT-06 Stationary background profile without activity recognition

- **Area:** background tracking (Dart policy). **Size:** S. **Tier:** Sonnet.
- **Files:** `app/lib/services/tracking_cadence.dart:33-34,431-448`, `app/test/services/tracking_cadence_test.dart`,
  `docs/live-tracking-client.md`.
- **Why:** when the native STILL profile is unavailable (API < 29, permission denied, non-Google client) the Dart
  stationary profile asks for high-accuracy GPS every 60 s all day.
- **Do:** stationary background becomes balanced accuracy, 180 s, 0 m filter (the server dedup and the heartbeat keep
  liveness); idle stays 3 min balanced with a 30 m filter.
- **Expected win:** GPS fixes per hour while still from 60 to 20 on phones without activity recognition; "last seen"
  freshness stays under 10 min (heartbeat).
- **Risk:** low. **Dependencies:** none. **Done:** cadence unit tests updated; policy table in the docs updated.

### OPT-07 Watch snapshots only on meaningful change, at the cadence the watch asked for

- **Area:** watch (Dart bridge, Kotlin, Swift). **Size:** M. **Tier:** Opus (three code bases, one contract).
- **Files:** `app/lib/services/watch/watch_snapshot.dart` (`watchContentHash`, `_member`: snap lat/lon to 50 m,
  bucket `fixAt` to the minute, drop the formatted `line`, send `since`/`lastSeen` timestamps),
  `app/lib/services/watch/watch_bridge.dart` (`minInterval` 5 s when a `watching` command is fresh, 60 s otherwise;
  alerts, `lastCommand`, unread and sharing bypass the slow tier), `wear/.../logic/Presenter.kt`,
  `wear/.../logic/Format.kt`, `wear/.../WearViewModel.kt` and `MainActivity.kt` (send `watching` on RESUMED and every
  30 s while resumed), `app/ios/OrbitlyWatch/PhoneLink.swift`, `Format.swift`, `docs/design/WATCH_APPS.md`,
  `docs/design/WATCH_APPS_APPLE.md`.
- **Why:** the hash includes a millisecond timestamp and a formatted status line, so almost every roster frame produces
  a snapshot (up to 720 per hour) that wakes the watch's listener service.
- **Expected win:** background snapshots per hour from up to 720 to 12 or fewer when idle and about 60 while someone
  drives; watch listener wakes, prefs writes and Bluetooth transfers down by the same factor; no minute-tick snapshots.
- **Risk:** medium: SOS and check-in results must still arrive immediately (bypass list); ages formatted on the watch
  must match the phone's wording (shared test vectors in `docs/design/WATCH_APPS.md`).
- **Dependencies:** none; coordinate with the Galaxy Watch Ultra Compose workstream on `Screens.kt`. **Done:** Dart
  unit test that 100 jittery frames within 50 m produce one snapshot; Kotlin unit test for the age formatter; a
  `dumpsys activity service WearableService` count on a watch for one idle hour recorded.

### OPT-08 Watch: urgent only when it matters, gate surface refreshes, drop REST polling

- **Area:** watch (Dart, Kotlin). **Size:** S-M. **Tier:** Sonnet (Dart and Kotlin parts are mechanical).
- **Files:** `app/android/app/src/main/kotlin/.../WatchBridgePlugin.kt:141-147` (`setUrgent` only when the Dart side
  passes `urgent: true`), `app/lib/services/watch/watch_bridge.dart:227-306,500-526` (feed alerts, sharing, unread from
  `AlertEvents`, `FamilyService.onSharingChanged`, `ChatEvents.unreadTotal` instead of `AlertService.list` and
  `SharingService.pauseStatus` every minute; run the members pre-hash before `_source.read()`),
  `wear/.../data/SnapshotRepository.kt:38-88` (surface key; `requestUpdate` and `requestUpdateAll` only when it changed
  or 60 s passed; write the prefs copy at most once a minute), `CircleTileService.kt`, `NearestComplicationService.kt`.
- **Expected win:** about 120 HTTP requests per hour removed from the phone while a watch is connected; immediate
  Bluetooth syncs from 720 per hour to only user-visible events; tile and complication service binds from about 2,000
  per hour to about 100.
- **Risk:** low (position staleness is bounded by OPT-07's tiers).
- **Dependencies:** OPT-07 for the tiers (can land first). **Done:** Dart test that an unchanged roster performs no
  HTTP; Kotlin test for the surface key; release Wear APK built.

### OPT-09 Wear OS: event-driven phone link state

- **Area:** watch (Android native). **Size:** S. **Tier:** Opus.
- **Files:** `wear/app/src/main/res/values/wear.xml` (declare a capability), `app/android/app/src/main/AndroidManifest.xml:139-147`
  (add `CAPABILITY_CHANGED` to the listener filter), `app/android/.../WatchListenerService.kt` (`onCapabilityChanged`
  drives `peerChanged` and the sign-out debt; remove the dead `onPeerConnected` path), `docs/design/WATCH_APPS.md:76-78`.
- **Why:** the current manifest never delivers peer events, so the phone publishes to an absent watch for up to 10
  min and the first snapshot after reconnect can be 10 min late.
- **Expected win:** zero snapshots built while no watch is connected; first snapshot within seconds of reconnect.
- **Risk:** low; confirm on a device with logcat (the finding is inferred from the manifest).
- **Dependencies:** none. **Done:** release phone and Wear APKs built; logcat shows `onCapabilityChanged` on watch
  connect and disconnect.

### OPT-10 Wear OS: baseline profile and release-build verification

- **Area:** watch (Gradle, Kotlin). **Size:** S-M. **Tier:** Sonnet.
- **Files:** `wear/app/build.gradle.kts` (`androidx.profileinstaller`, a committed `baseline-prof.txt` covering
  `MainActivity`, `WearApp`, `ScreenList`, `Snapshot.parse`, tile and complication services), `wear/.../ui/Screens.kt`
  (`items(rows, key = { it.id })`, `remember(snapshot, here)` for `Presenter.rows`),
  `wear/.../data/SnapshotRepository.kt` and `WearViewModel.kt` (content flow with `distinctUntilChanged`, timestamp in
  a separate flow, 60 s age ticker).
- **Why:** Google names baseline profiles and R8 as the first Wear performance tools; the Ultra's Exynos W1000 is fast,
  so lag there is software. The Galaxy Watch Ultra Compose workstream owns the specific jank fixes; this item is the
  build-level part and the list keys.
- **Expected win:** 15-30% faster cold start (Google's range; Todoist measured 14% on Wear), fewer first-scroll jank
  frames; keep-alive snapshots no longer recompose every screen.
- **Risk:** low. **Dependencies:** none. **Done:** `adb shell dumpsys package dexopt` shows `speed-profile` for the
  Wear package on the Ultra after `bg-dexopt-job`; stopwatch cold start before and after recorded.

### OPT-11 Phone startup: nothing but the session check before the shell

- **Area:** phone app (Dart). **Size:** S. **Tier:** Sonnet.
- **Files:** `app/lib/main.dart:249-260,288-318`, `app/lib/services/offline/offline_cache.dart:127-146` (cache-first
  or stale-while-revalidate for `server-config`), `app/lib/services/tile_config.dart:33`,
  `app/test/services/startup_requests_test.dart`.
- **Why:** the gate awaits 5-6 serial Keystore round trips and a network-first `/config` with a 4 s timeout; on
  timeout the cached style is not applied.
- **Expected win:** splash shortened by 100-400 ms on low-end phones (Keystore) and by up to 4 s on slow links; correct
  map style on an offline start.
- **Risk:** low (housekeeping is idempotent; background start already waits for the first frame).
- **Dependencies:** none. **Done:** startup request test shows the gate issues only the session check before first
  frame; `scripts/perf/startup-time.sh` median on the Fold 4 recorded.

### OPT-12 Map: cap the motion ticker and isolate bubble repaints

- **Area:** phone app (Dart). **Size:** S. **Tier:** Sonnet.
- **Files:** `app/lib/screens/map_screen.dart:333-339,1557-1571`, `app/lib/services/member_motion_hub.dart:90-98`,
  `app/lib/widgets/member_avatar_bubble.dart`, `app/test/perf/*`.
- **Do:** skip alternate ticks when `display.refreshRate > 90`; stop the ticker when every animating pin moves less
  than 0.5 px per frame; wrap each bubble and cluster child in a `RepaintBoundary` so per-frame repositioning
  translates a cached layer instead of re-rasterising the blurred shadows.
- **Expected win:** marker-layer rebuilds and raster work during a drive halved on 120 Hz devices (Fold 4); N blurred
  shadows no longer rasterised per frame. No visual change at a 1 Hz data rate.
- **Risk:** low (watch layer count; about 6-10 boundaries). Coordinate with the Fold 4 rendering workstream.
- **Dependencies:** none. **Done:** `PERFMETRIC` for layer rebuilds per 20 frames at 120 Hz; Performance screen jank %
  during a drive recorded on the Fold 4.

### OPT-13 Map: raster tile mode on the lite tier and a disk cache for raster layers

- **Area:** phone app (Dart). **Size:** S-M. **Tier:** Sonnet.
- **Files:** `app/lib/widgets/openfamily_map_layers.dart:48-55,91-106`, `app/lib/services/perf/perf_profile.dart`,
  `app/lib/services/tile_config.dart`.
- **Do:** `VectorTileLayerMode.raster` when the tier is lite (vector stays on standard and full); a disk-cached
  `TileProvider` for the raster fallback and satellite layers sized from `tileDiskCacheBytes`.
- **Expected win:** pan and zoom raster time on 2-3 GB phones drops from per-frame geometry painting to texture blits
  (typically halves jank while panning); satellite tiles survive restarts.
- **Risk:** low-medium (slightly blurrier labels during zoom on lite). **Dependencies:** none. **Done:** widget test
  that the lite tier builds the raster mode; manual pan test on a 3 GB phone recorded.

### OPT-14 No polling while backgrounded: CrashWatcher and FamilyService lifecycle

- **Area:** phone app (Dart). **Size:** M. **Tier:** Opus (socket lifecycle and the background-isolate signal).
- **Files:** `app/lib/services/driving/crash_watcher.dart:25-38`, `app/lib/screens/app_shell.dart:80`,
  `app/lib/services/family_service.dart:385-392,415-432,476-477`, `app/lib/screens/map_screen.dart:628-667`.
- **Do:** gate `CrashWatcher` on a `crashEnabled` notifier and signal pending crashes from the background isolate over
  the existing channel instead of a 3 s disk poll; on `AppLifecycleState.paused` stop the staleness timer and either
  close the socket or stretch ping and watchdog to 5 min; reconnect on resume (the resume path already refetches members).
- **Expected win:** 1,200 prefs reads per hour removed; two radio wakeups per minute removed while the app sits in the
  background under the location service. Coordinate with the driving workstream on `CrashWatcher`.
- **Risk:** medium: alerts and chat arriving in the background must be covered by push (they are, by design); the crash
  notification tap path must keep working.
- **Dependencies:** none. **Done:** unit tests for both lifecycles; Performance screen WebSocket per-minute counters
  show zero while backgrounded.

### OPT-15 Enforce the APK size budget

- **Area:** CI. **Size:** S. **Tier:** Sonnet.
- **Files:** `scripts/apk-size-baseline.txt` (record from the current arm64 release APK), `.github/workflows/apk.yml:164`
  (drop the `|| echo` wrapper so the step fails), `docs/developers/build.md` (how to update the baseline).
- **Expected win:** the budget exists; regressions are caught per PR. **Risk:** none.
- **Dependencies:** none. **Done:** a deliberate +6% test build fails the step; baseline committed.

### OPT-16 Server: fewer queries per request, container-aware runtime

- **Area:** server (Go, deploy). **Size:** S. **Tier:** Sonnet.
- **Files:** `backend/internal/middleware/middleware.go:54-80` and `ingest_key.go:125-200` (in-process token-version
  cache with a 5-10 s TTL, invalidated by the bump paths in `handlers/account*.go`), `handlers/e2ee_channel.go:162-168`
  (`circleModes` cached 30-60 s, invalidated on circle and E2EE mutations), `ingest_key.go:138` (pass the buffered body
  to the handler), `backend/internal/db/db.go:44-51` (`MinConns = 3`), `docker-compose.yml:151-175` and
  `backend/Dockerfile` (`GOMEMLIMIT=400MiB`, API `cpus: 2.0`, explicit Postgres settings for the 1 GB container),
  `docs/admin/deployment-profile.md`.
- **Expected win:** one to two queries fewer on every authenticated request and every fix (about 15% of the per-fix
  statement count); no pool cold starts after idle; no OOM kills under GC lag; Postgres sized to its cgroup.
- **Risk:** low (stale token version up to 10 s after a password change; the WS path disconnects directly anyway).
- **Dependencies:** none. **Done:** handler tests with the cache; `go test -p 1` green; compose file reviewed by the
  demo-server workstream.

### OPT-17 Server: ingest transaction without fsync, one index fewer

- **Area:** server (SQL). **Size:** S. **Tier:** Opus (data-durability decision, index drop).
- **Files:** `backend/internal/handlers/location.go:115`, `location_batch.go:250` (`SET LOCAL synchronous_commit = off`
  inside the ingest transactions only), new migration in the architecture range dropping `idx_locations_device_ts`
  (the unique `(device_id, ts)` index remains) and, after a grep for spatial predicates on `locations.geom`, the GIST
  index, `docs/live-tracking.md:98-116` (statement count and WAL note).
- **Expected win:** per-fix fsync removed (the project measured WAL cost dominating ingest: 280 ms to 8 ms in
  `docs/live-tracking.md`); index writes per insert from 3 to 1 (about 30-40% less write amplification, smaller chunks).
- **Risk:** medium: up to one second of location rows lost on a crash (accepted; accounts untouched); the GIST drop needs
  the grep and a note in the migration.
- **Dependencies:** none. **Done:** `BenchmarkIngestMoving` before and after with `fsync=on` recorded; migration applied
  in the test suite; `EXPLAIN` of the members and history queries unchanged.

### OPT-18 Server: one WebSocket keepalive, write deadlines, slower revalidation

- **Area:** server and app (Go, Dart). **Size:** S. **Tier:** Opus (client and server must agree on deadlines).
- **Files:** `backend/internal/handlers/hub.go:19-84` (drop the server protocol ping or the client JSON ping; 10 s
  write deadline per `conn.Write`), `handlers/ws.go:183,284-307` (revalidate every 5 min), `app/lib/services/family_service.dart:476-477`
  (client ping 60 s, watchdog 150 s), `web/src/map/MapView.tsx` (same), `docs/live-tracking.md`.
- **Expected win:** radio wakeups for keepalives from 4 to 1 per minute per phone; 2 queries per socket per 30 s
  removed; stalled peers no longer block a writer goroutine.
- **Risk:** low-medium: old clients (compat) still ping every 30 s, which the server must keep accepting.
- **Dependencies:** none; gate the new server deadline through `compat.Features`. **Done:** hub tests for the deadline;
  app test for the new ping period; one idle socket observed for 10 min on the demo server.

### OPT-19 Server: geofence evaluation that costs nothing when there is nothing to evaluate

- **Area:** server (Go, SQL). **Size:** M. **Tier:** Opus.
- **Files:** `backend/internal/handlers/geofence_eval.go:93-433` (cached "enabled geofences per user" count, skip when
  zero; one `UPDATE ... RETURNING` per candidate instead of a four-statement transaction), `handlers/ws.go:482-490`
  (`broadcastPresence` uses `OwnAndSharingCircles`, 2 queries to 1).
- **Expected win:** 5-17 statements per fix removed for users without places (most), 6 to 2 round trips per candidate
  for the rest.
- **Risk:** medium (arrival and departure semantics must not change; the existing geofence tests are the contract).
- **Dependencies:** none. **Done:** geofence tests green; statement count per fix measured with `pg_stat_statements` in a
  test and written into `docs/live-tracking.md`.

### OPT-20 Admin web: back off polls, lazy pages, precompressed assets

- **Area:** admin web (React, Vite, Go static serving). **Size:** S. **Tier:** Sonnet.
- **Files:** `web/src/pages/BackupsCard.tsx:59` (2.5 s to 10 s and only while a job runs), `ServerSetupCard.tsx:211`
  (5 s to 30 s), `SystemPage.tsx:66` (30 s to 60 s, pause when `document.hidden`), `web/src/App.tsx:38-49` (lazy-load
  Settings, System, Fleet, Audit, Builds, Sessions and the `@noble/*` E2EE code), `web/vite.config.ts` and
  `backend/cmd/server/main.go:880-900` (ship `.br`/`.gz` from the build; serve them instead of gzipping JS on the fly
  on a 1-CPU API). Rebuild `backend/web/dist` and commit it.
- **Expected win:** shell JavaScript from 485 KB toward 250 KB; 8-13 admin queries per 30 s poll removed while the tab
  is hidden; no on-the-fly compression CPU for static assets.
- **Risk:** low. **Dependencies:** none. **Done:** Vite build output sizes recorded in `docs/admin/deployment-profile.md`;
  web tests green.

### OPT-21 Release measurement on hardware

- **Area:** measurement. **Size:** S per device (human time). **Tier:** any (a checklist).
- **Files:** release notes for v1.0; `docs/performance.md` "Measure on the phone".
- **Do:** run `scripts/perf/startup-time.sh` on the Fold 4 and a 3 GB phone; copy the Performance screen report after a
  10-minute drive; 8-hour `batterystats` soaks (stationary and with a drive); Settings > Battery on the Galaxy Watch
  Ultra and the Apple Watch; `dumpsys activity service WearableService` counters; Xcode Organizer launch time on the
  oldest supported iPhone; Play pre-launch report. Record the numbers in the baselines table of the architecture page.
- **Expected win:** the budgets become real numbers; regressions after v1 have a reference. **Risk:** none.
- **Dependencies:** ideally after OPT-01 to OPT-05 land, but a "before" run is valuable on its own. **Done:** the table
  in `OPTIMIZATION_ARCHITECTURE.md` section 9 has no "pending" device rows.

### OPT-22 E2EE: coalesce per-fix persistence

- **Area:** phone app (Dart, crypto pipeline). **Size:** M. **Tier:** Opus.
- **Files:** `app/lib/services/e2ee/private_runtime.dart:635-690,772` (`_sealFix`, `_scheduleFlush`),
  `app/lib/services/e2ee/private_channel.dart:528-620` (`SealedQueue`: in-memory buffer with a write-behind of a few
  seconds, persisted immediately only when the flush is deferred or the isolate is about to end), `PrefsChannelKv`
  callers for `sealedAt` (write at most once a minute).
- **Why:** per private circle per fix, four to six whole-file prefs writes precede a batched upload; at 1 Hz driving
  that is several file rewrites per second.
- **Expected win:** storage writes per fix from 4-6 per circle to about 1 per flush; less CPU and flash wear in the
  background isolate during drives.
- **Risk:** medium: the queue must survive a process kill between seal and flush (persist on a short timer and on
  `dispose`; parked fixes already cover the failure path). The cross-isolate `reload()` discipline must stay.
- **Dependencies:** none. **Done:** E2EE tests green; a unit test counts prefs writes for 60 sealed fixes (<= 2).

### OPT-23 One breakpoint helper for the shell, the two-pane view and the camera offsets

- **Area:** phone app (Dart, layout). **Size:** M. **Tier:** Sonnet.
- **Files:** `app/lib/screens/app_shell.dart:55-56`, `app/lib/widgets/location_tab_view.dart:513-515`,
  `app/lib/screens/map_screen.dart:205-226,825-835`, new `app/lib/theme/breakpoints.dart`, golden tests.
- **Why:** three definitions on two width sources disagree in the 720-920 dp band, where the unfolded Fold 4 lives.
  The Fold 4 rendering workstream fixes the visible bug; this removes the cause class.
- **Expected win:** no sheet-versus-panel disagreement; consistent large-screen layout on tablets.
- **Risk:** medium (behaviour change on tablets; goldens). **Dependencies:** land after the Fold 4 fix merges.
  **Done:** golden tests at 600, 720, 841x701 (foldable), 1024 dp.

### OPT-24 Server batch ingest: two statements per batch, not two per point

- **Area:** server (SQL). **Size:** S. **Tier:** Sonnet.
- **Files:** `backend/internal/handlers/location_batch.go:199-214,249-332` (`INSERT ... SELECT unnest($1::...)`, one
  `member_positions` upsert for the max-ts point, drop the unused `family_id` read).
- **Expected win:** 1,001 statements per 500 points to 3; per-point server cost measured by `BenchmarkIngestBatch500`
  expected to drop by half or more. Matters once OPT-03 makes batches the common path.
- **Risk:** low (same transaction, same dedupe). **Dependencies:** none. **Done:** batch tests green; benchmark before
  and after recorded in the architecture page.

## LATER (after v1.0)

### OPT-30 Stationary without GPS: exit geofence as the wake signal

- **Area:** background tracking (Android and iOS native). **Size:** L. **Tier:** Opus.
- **Files:** `app/packages/background_locator_2/android/...` (Geofencing API, 150 m exit, 5 min responsiveness,
  re-register on boot), `ios/Classes/BackgroundLocatorPlugin.m` (`CLMonitor` or `CLCircularRegion` while still),
  `tracking_cadence.dart` (a `parked` tier with no GPS request).
- **Expected win:** GPS off entirely while still on both platforms; the research puts stationary drain under 1% per
  hour for such designs. **Risk:** high (OEM geofence latency and reliability vary; needs a device matrix and a
  fallback timer). **Dependencies:** OPT-02, OPT-05. **Done:** drive-away test on 3 Android OEMs and 1 iPhone with
  departure detected within 6 min.

### OPT-31 Return the family's latest positions in the upload response

- **Area:** server and app contract. **Size:** M. **Tier:** Fable (changes the live-data model for backgrounded phones).
- **Files:** `backend/internal/handlers/location.go`, `location_batch.go`, `app/lib/services/background_location_service.dart`,
  `widget_snapshot.dart`, `watch_bridge.dart`, `docs/developers/api.md`.
- **Why:** OwnTracks' pattern: a phone that just uploaded needs no socket to know where the family is; home-screen
  widgets and watches could be fed from the background isolate without a foreground WebSocket.
- **Expected win:** background phones hold no socket at all; widget and watch data without the UI isolate running.
  **Risk:** medium (payload size, E2EE circles cannot use it). **Done:** compat-gated response field; widget updated from it.

### OPT-32 Members endpoint: one CTE and a cheap version precheck for 304

- **Area:** server (SQL). **Size:** M. **Tier:** Opus.
- **Files:** `backend/internal/handlers/family.go:263-411`, `handlers/ws.go:315-419`, `handlers/wire.go:61-81`,
  `middleware/etag.go`, `handlers/place_presence.go`.
- **Expected win:** 7+N queries to 2; a 304 costs one query instead of the full set; typed compact struct instead of
  marshal-unmarshal-marshal. **Risk:** medium (visibility rules are subtle; the existing tests are the contract).
  **Done:** `perf_endpoints_test.go` members p95 recorded before and after.

### OPT-33 One labelled WebSocket frame per fix; server-side coalescing

- **Area:** server and app. **Size:** M. **Tier:** Opus.
- **Files:** `backend/internal/handlers/hub.go:550-576`, `handlers/ws.go:57-72` (`omitempty`), `app/lib/services/family_service.dart`
  (filter by `circle_ids`), `web/src/map/MapView.tsx`.
- **Expected win:** N frames per fix for a subject in N shared circles become 1; nulls dropped from the frame.
  **Risk:** medium (compat-gated). **Done:** WS counters on the Performance screen show received equals applied.

### OPT-34 Push: commands over the live socket, collapse ids and priorities

- **Area:** server. **Size:** S-M. **Tier:** Sonnet (headers) and Opus (delivery path).
- **Files:** `backend/internal/push/push.go:305-343,462-524` (`apns-collapse-id`, ntfy `Priority`, `Tags`, `Cache: no`),
  `handlers/push_direct.go`, `handlers/location_request.go:289-330`, `handlers/watch.go:186-201`,
  `handlers/notification_prefs.go:111-130` (cache `recipients()` 60 s), `handlers/chat.go:513-553` (concurrent dispatch
  with a bounded semaphore).
- **Expected win:** one long-lived connection per phone instead of WebSocket plus SSE; coalesced command pushes;
  faster chat fan-out. **Done:** push tests; a phone with direct push holds one connection in `netstat`.

### OPT-35 Trips report without the per-trip point scan

- **Area:** server (Go, migration). **Size:** M. **Tier:** Sonnet.
- **Files:** `backend/internal/trips/store.go:463-517`, `segment.go`, new migration adding `speed_events` to `trips`,
  a backfill by recompute, `handlers/trips*.go`.
- **Expected win:** `GET /trips/report` from up to 200 hypertable range scans to 1 query. **Done:** `perf_endpoints_test.go`
  report month p95 recorded.

### OPT-36 Admin web: one map engine

- **Area:** admin web. **Size:** L. **Tier:** Sonnet.
- **Files:** `web/package.json`, `web/src/map/*`, `web/src/pages/HistoryLayers.tsx`, `PlacesPage.tsx`.
- **Expected win:** the 1.06 MB map chunk to about 0.6 MB. **Risk:** medium (feature parity of drawing and layers).

### OPT-37 Flutter frame-time gate in CI on a self-hosted device

- **Area:** CI. **Size:** M. **Tier:** Sonnet.
- **Files:** `app/integration_test/perf_*.dart`, `app/test_driver/perf_driver.dart`, a self-hosted runner workflow.
- **Expected win:** p90 build <= 8 ms and missed-budget <= 1% enforced on the map scroll and the people list; medians
  of 3 runs, 15% tolerance, fail only on two consecutive regressions.

### OPT-38 Wear OS Macrobenchmark module

- **Area:** watch CI. **Size:** M. **Tier:** Sonnet.
- **Files:** `wear/macrobenchmark/*` (startup and `FrameTimingMetric` on the people list), workflow on a self-hosted
  runner with a watch attached. **Expected win:** generated baseline profile; regression detection for the Ultra.

### OPT-39 Wear OS: distance and bearing from the `you` member; remove watch location

- **Area:** watch (Kotlin). **Size:** M. **Tier:** Opus.
- **Files:** `wear/.../logic/Presenter.kt`, remove `data/LastLocation.kt`, `ui/WearApp.kt:23` permission flow,
  `AndroidManifest.xml` location permissions, `CircleTileService.kt`, `NearestComplicationService.kt`.
- **Expected win:** no location permission prompt on the watch, deterministic sorting, fewer binder calls per tile
  request; identical semantics to the Apple app. **Risk:** low-medium (assumes phone and watch are co-located, the
  companion premise).

### OPT-40 Apple Watch: reachability-aware publishing

- **Area:** watch (Swift, Dart). **Size:** S. **Tier:** Opus.
- **Files:** `app/ios/Runner/WatchBridge.swift:82-121`, `app/lib/services/watch/watch_bridge.dart:33-53`.
- **Expected win:** the 5 s tier applies only while the watch is reachable; identical contexts are not re-sent (drop
  `sentAt` or move it into the JSON timestamp). **Done:** iOS CI build; a day of use with the watch asleep shows no
  context churn in the console.

### OPT-41 Narrow ProGuard keeps

- **Area:** Android build. **Size:** M. **Tier:** Opus (reflection regressions).
- **Files:** `app/android/app/proguard-rules.pro`.
- **Expected win:** 0.5-1.5 MB of dex. **Risk:** medium (Gson models in `background_locator_2`, Tink keyset paths).
  **Done:** release APK exercised on a device: background tracking, E2EE, push, watch.

### OPT-42 Impeller smoke test on Mali and MediaTek 3-4 GB phones

- **Area:** QA. **Size:** S. **Tier:** any.
- **Do:** run the release build on one Galaxy A-series (Mali) and one MediaTek phone; record raster p99 and graphics
  memory; if a device crashes, document the opt-out (deprecated but still honoured) as a support answer, not a default.

### OPT-43 Leak gates for the map and member widgets

- **Area:** phone app tests. **Size:** M. **Tier:** Sonnet.
- **Files:** `app/test/**` with `leak_tracker`; `MemoryPressureGuard` trimmers for the vector-tile memory cache and
  `MapStyleService._styles`. **Done:** zero growth after 20 open/close cycles of the map screen in DevTools on a 3 GB phone.

### OPT-44 Server CPU: `encoding/json/v2`, PGO

- **Area:** server. **Size:** S. **Tier:** Sonnet. Only after the server is CPU-bound in a measurement; expected 2-14%.

### Not planned

- Protobuf or CBOR wire format for the app (gzip JSON plus off-isolate decoding is enough; a format change costs a
  compat matrix).
- Removing PostGIS (places use it).
- Flutter deferred components (Play-only; sideloaded APKs are a supported path).
- A default Impeller opt-out (deprecated upstream).
- An Apple Watch complication for v1 (50 transfers a day needs its own cadence design).

## Top 10 for v1.0 at a glance

| # | Item | Area | Tier | Size | Headline win |
|---|---|---|---|---|---|
| 1 | OPT-02 iOS stationary mode and adaptive cadence | background (iOS) | Opus | M-L | GPS off while still on iOS |
| 2 | OPT-03 batch when not live (+ OPT-01 persistent client) | background | Opus + Sonnet | M + S | 3,600 to 60 requests per driving hour; server work -95% |
| 3 | OPT-07 watch snapshots on meaningful change, watch-requested cadence | watch | Opus | M | 720 to 12-60 snapshots per hour |
| 4 | OPT-08 + OPT-09 watch urgent/surface gating, REST polling off, link events | watch | Sonnet + Opus | S-M | -120 requests per hour; no publishing to an absent watch |
| 5 | OPT-05 + OPT-06 FLP batching, cheaper stationary profile | background (Android) | Opus + Sonnet | S + S | wakeups -98% while driving unwatched; GPS fixes -66% while still |
| 6 | OPT-11 + OPT-12 + OPT-13 startup gate, ticker cap, raster on lite | phone UI | Sonnet | S each | faster first frame; half the raster work on 120 Hz; smooth panning on 3 GB |
| 7 | OPT-14 no polling while backgrounded | phone | Opus | M | 2 radio wakeups per minute and 1,200 disk reads per hour removed |
| 8 | OPT-16 + OPT-17 + OPT-24 server queries, fsync, batch SQL | server | Sonnet + Opus | S each | per-fix statements 16-28 to under 8; batch 1,001 to 3 statements |
| 9 | OPT-18 + OPT-19 one keepalive, geofence skip | server | Opus | S + M | keepalive wakeups -75%; 5-17 statements per fix removed for most users |
| 10 | OPT-15 + OPT-21 size budget enforced, hardware measurements | CI, QA | Sonnet, any | S | the budgets become numbers |

OPT-10 (Wear baseline profile), OPT-20 (admin web polls) and OPT-22 (E2EE write coalescing) follow as soon as the ten
above are assigned.
