# Research notes: how serious apps optimise battery, latency and smoothness

Sourced findings (official docs, engineering blogs, WWDC and Google I/O talks) behind the optimisation architecture and backlog, grouped by platform, with the numbers that set our budgets.

Companion pages: [Optimisation architecture](OPTIMIZATION_ARCHITECTURE.md) (what we do with these findings) and the
[Optimisation backlog](OPTIMIZATION_BACKLOG.md) (the work items). Collected 2026-11-08; Apple pages were read through
their `.md` documentation endpoints and WWDC transcripts because the HTML is script-rendered. Vendor numbers (Life360,
Timescale, Samsung) are marked as self-reported.

## 1. Background location at scale

### What the big apps do

- **Life360** publishes no interval. Its support page describes an algorithm that "helps us decide when to wake up your
  phone and update your location to avoid leaving your GPS on", budgets "about 10% shorter battery life in a 24-hour
  period", and turns on "high-precision GPS" only "when the device is in transit".
  https://support.life360.com/hc/en-us/articles/23053716563223-Life360-and-Battery-Usage (self-reported). The CEO
  described the trigger: at a known place it "will shut off GPS and listen for signals that you're changing locations"
  (Wi-Fi set churn, cell), then "Once you're in motion, it will flip the GPS on". https://venturebeat.com/ai/life360-battery
- **Apple Find My network**: offline finding relays end-to-end encrypted BLE sightings; "Approximately every 15 minutes,
  the public key is replaced"; "minimal impact on battery life". No person-to-person cadence is published.
  https://support.apple.com/guide/security/find-my-security-sec6cbc80fd0/web
- **Google Find Hub** throttles by design: it "limits the number of times that a nearby Android device can contribute a
  location report" and "throttles how frequently the owner ... can request an updated location"; devices near the user's
  home do not contribute. https://security.googleblog.com/2024/04/find-my-device-network-security-privacy-protections.html
- **Strava** asks for high-accuracy mode and every OEM battery saver disabled; Beacon live sharing is reported at roughly
  15 s updates. https://support.strava.com/hc/en-us/articles/216918967 ,
  https://www.androidauthority.com/strava-beacon-location-sharing-2741621
- **Google Maps Timeline** is on-device since December 2024 and publishes no cadence.
  https://support.google.com/maps/answer/6258979 , https://9to5google.com/2024/12/11/google-maps-on-device-timeline/
- **OwnTracks** (open source) documents its two modes: significant mode publishes only at ">500m and at most once every
  5 minutes" (iOS) or every 15 minutes with a 500 m displacement filter (Android); move mode is 100 m / 300 s on iOS and
  a 10 s high-power interval on Android, recommended "while charging or during trips". Friends' positions ride back in
  the upload response, so a backgrounded client needs no second channel. https://owntracks.org/booklet/features/location/ ,
  https://owntracks.org/booklet/tech/http/
- **Traccar** stores positions append-only and keeps "Last position id ... in the devices table" (a latest-row pointer),
  with one WebSocket carrying `devices`, `positions`, `events`. https://www.traccar.org/forums/topic/mass-query-last-position/ ,
  https://www.traccar.org/traccar-api/

### iOS Core Location power tools

- Significant-location-change: "500 meters or more ... not expect notifications more frequently than once every five
  minutes"; relaunches a terminated app. Apple's energy guide warns it runs "around the clock" and prefers region and
  visit monitoring. https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges() ,
  https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html
- Region monitoring: "up to 20 regions at a time", radii "between 1 and 400 meters work better", delivery "within 3 to
  5 minutes on average". CLMonitor (iOS 17) keeps the 20-condition cap, persists until reboot.
  https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoring(for:) ,
  https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions
- Visits (CLVisit): system-detected arrivals and departures, works with reduced accuracy, relaunches the app.
  https://developer.apple.com/documentation/corelocation/clvisit
- `CLLocationUpdate.liveUpdates` (iOS 17) pauses itself: "once the device is in stationary state for a sufficient
  amount of time ... trigger Automatic Pause" and resumes "without any user interaction".
  `CLBackgroundActivitySession` owns the blue indicator and "you must start the new session from the foreground".
  https://developer.apple.com/videos/play/wwdc2023/10180/ ,
  https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background
- iOS 18 `CLServiceSession`: "Always authorization will only be effective when you hold one of these"; approximate
  location "is updated only every 15 to 20 minutes". https://developer.apple.com/videos/play/wwdc2024/10212/
- Defaults that cost: `desiredAccuracy` defaults to `kCLLocationAccuracyBest`; `pausesLocationUpdatesAutomatically`
  defaults to true but a pause "ends access to location changes until the app launches again" for When-In-Use apps, so
  Apple suggests disabling it and dropping to `kCLLocationAccuracyThreeKilometers` in the background instead.
  Deferred updates are deprecated since iOS 13. https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy ,
  https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically
- `CMMotionActivityManager` reports "walking, running, in a vehicle, or stationary" from the motion coprocessor.
  https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager

### Android

- Google's battery model is accuracy x frequency x latency: "Pass the largest possible value when using
  setIntervalMillis()"; set `setMaxUpdateDelayMillis()` "several times larger than the interval" so fixes arrive in
  batches; geofence responsiveness "five minutes or larger is recommended"; avoid `PRIORITY_HIGH_ACCURACY` "for
  sustained background work". Worked example: 10 min interval + 60 min max delay "delivers approximately six location
  data points in a batch approximately every hour". https://developer.android.com/develop/sensors-and-location/location/battery ,
  https://developer.android.com/develop/sensors-and-location/location/battery/optimize
- `LocationRequest.Builder`: `setMaxUpdateDelayMillis` (default 0, no batching), `setMinUpdateDistanceMeters`,
  `setWaitForAccurateLocation`. https://developers.google.com/android/reference/com/google/android/gms/location/LocationRequest.Builder
- Android 8+ background limits: background apps "can receive location updates only a few times each hour"; a
  foreground service is the way out, and on Android 11+ starting one from the background needs
  `ACCESS_BACKGROUND_LOCATION`. https://developer.android.com/about/versions/oreo/background-location-limits
- Geofencing API: "limit of 100 per app, per device user"; minimum radius "between 100 - 150 meters"; latency "usually
  ... less than 2 minutes", "up to 6 minutes" when long stationary; re-register after reboot.
  https://developer.android.com/develop/sensors-and-location/location/geofencing
- Activity Recognition Transition API: ENTER/EXIT for `IN_VEHICLE, ON_BICYCLE, RUNNING, STILL, WALKING`; "The latency of
  event detection might vary by device." https://developer.android.com/develop/sensors-and-location/location/transitions
- Doze: while-idle alarms "cannot fire ... more than once per nine minutes, per app"; standby buckets cap alarms
  (working set 10/h, frequent 2/h, rare 1/h); apps holding `ACCESS_BACKGROUND_LOCATION` are exempt from the restricted
  bucket; Doze exemption is "Acceptable" for a "Safety app. Apps that keep their users and their families safe."
  https://developer.android.com/training/monitoring-device-state/doze-standby ,
  https://developer.android.com/topic/performance/power/power-details , https://developer.android.com/topic/performance/appstandby
- Foreground service types (Android 14): `foregroundServiceType="location"` plus `FOREGROUND_SERVICE_LOCATION`, also
  declared in Play Console. https://developer.android.com/develop/background-work/services/fgs/service-types
- Exact alarms: `SCHEDULE_EXACT_ALARM` is user-revocable and "not pre-granted to fresh installs of apps targeting
  Android 13"; inexact windows are clipped to 10 min; WorkManager periodic minimum 15 min.
  https://developer.android.com/develop/background-work/services/alarms/schedule
- OEM killers: Samsung puts "any app which is not started in 3 days ... to sleep" by default; One UI 6 honours
  Android 14 foreground services. https://dontkillmyapp.com/samsung

### Adaptive sampling

- RAPS (MobiSys 2010): turn GPS on only when position uncertainty exceeds a threshold, gate on a duty-cycled
  accelerometer, blacklist cell signatures where GPS fails; "increase phone lifetimes by more than a factor of 3.8 over
  an approach where GPS is always on." https://solar.cs.ucl.ac.uk/appoptimization.github.io/publications/PKG2010
- Radio baselines (old hardware, ordering still holds): GPS "approximately 400 mW", Wi-Fi 55 mW idle with ~1100 mW probe
  spikes; lifetimes 9 h GPS vs 40 h Wi-Fi vs 60 h GSM. https://eudl.eu/doi/10.1007/978-3-642-12607-9_14
- A commercial activity-tiered tracker reports "less than 1% per hour" stationary at 10 min reports, "2-3% per hour"
  walking at 5 min, "5-6% per hour" driving with GPS every 30 s (vendor numbers). https://blog.corvusgps.com/?p=809
- Urban GPS "can be off by 50 meters or more"; Uber corrects server-side with map matching and a particle filter.
  https://www.uber.com/blog/rethinking-gps/
- Trajectory compression: Douglas-Peucker is lossy and batch; delta encoding is "lossless ... zero error and a time
  complexity of O(n)". https://link.springer.com/content/pdf/10.1007/s13369-024-08956-0.pdf

## 2. Wear OS

- Google's Wear performance guide: "Start with the most effective performance tool types: baseline profiles (including
  startup profiles) and the R8 code optimizer." Verify with `adb shell dumpsys package dexopt` showing
  `status=speed-profile`; debug builds "impose a significant performance cost". Public Wear datapoint: Todoist ~14%
  median startup improvement. https://developer.android.com/training/wearables/compose/performance ,
  https://doist-dev.pages.dev/android-app-baseline-profiles
- Compose hygiene applies: `remember` expensive work, stable keys and `contentType`, lambda modifiers, and "Use Row or
  Column for small, bounded lists (1 to 10 items)". https://developer.android.com/develop/ui/compose/performance/bestpractices
- Horologist UI is retired: "use the components in M3"; Wear Compose Material 3 1.5.0 stable since 27 Aug 2025.
  https://developer.android.com/training/wearables/compose/migrate-to-material3 ,
  https://developer.android.com/jetpack/androidx/releases/wear-compose-m3
- Tiles: freshness "should not be used to update your tile more frequently than once a minute, and the system may
  throttle"; the power guide says "Disable automatic refresh, or increase the refresh rate to 2 hours or longer" and
  "Don't schedule work for your tile or complication when the user isn't interacting with it".
  https://developer.android.com/reference/androidx/wear/tiles/TileBuilders.Tile.Builder ,
  https://developer.android.com/training/wearables/apps/power
- Complications: `UPDATE_PERIOD_SECONDS` minimum 300 s, 0 means push-driven via `ComplicationDataSourceUpdateRequester`;
  `onComplicationRequest` "should ideally just return the value with minimal computation"; use
  `TimeDifferenceComplicationText` so ages tick without pushes.
  https://android-developers.googleblog.com/2025/08/building-complication-data-sources-wear-os.html
- Ongoing Activity is for work "likely to last longer than one minute" and explicitly not for "the status of an
  updating app". https://developer.android.com/training/wearables/ongoing-activity
- Always-on: at most 15% lit pixels, minute-granular updates, "--" for live values, no animation; `keepScreenOn`
  "severely impacts battery life". https://developer.android.com/training/wearables/always-on
- Data Layer: payload "limited to 100 KB"; non-urgent items "might delay up to 30 minutes ... usually ... only a few
  minutes"; "Clients should only setUrgent() for DataItems which need to be delivered right away"; "Transmit state
  changes instead of configuring rapid updates"; "Only transmit state changes that update your UI"; audit with
  `adb shell dumpsys activity service WearableService`. https://developer.android.com/training/wearables/data/data-items ,
  https://developers.google.com/android/reference/com/google/android/gms/wearable/PutDataRequest ,
  https://developer.android.com/training/wearables/apps/power
- Location on the watch: "WHS is recommended for all workout tracking"; FLP on a watch at balanced power, "no more than
  once per minute"; power table ranks network "Very high", GPS "High", Bluetooth "Medium".
  https://developer.android.com/training/wearables/apps/location-detection
- Galaxy Watch Ultra: 590 mAh, Exynos W1000 (3 nm, 1x A78 + 4x A55, 1.4 GHz), 2 GB RAM, 480x480; "Up to 60" h with
  AOD, 80 h without (Samsung, self-reported). Lag on this chip is software, not hardware.
  https://www.samsung.com/uk/support/mobile-devices/how-does-the-galaxy-watch-ultra-and-galaxy-watch7-compare-to-their-previous-models/ ,
  https://semiconductor.samsung.com/processor/wearable-processor/exynos-w1000/
- Wear OS 5 and 6: "running a marathon consumes up to 20% less power on Wear OS 5"; Wear OS 6 "up to 10% improvement
  in battery life", apps targeting SDK 36 are always-on by default with updates "as infrequent as once per minute".
  https://android-developers.googleblog.com/2024/05/whats-new-in-wear-os-io-24.html ,
  https://android-developers.googleblog.com/2025/05/whats-new-in-wear-os-6.html
- Vitals per watch model: crash 4%, ANR 5%, excessive battery 1%; ANR triggers include `startForeground` within 5 s and
  heavy work in composable bodies. https://developer.android.com/topic/performance/vitals ,
  https://developer.android.com/topic/performance/vitals/anr

## 3. Apple Watch

- Foreground-first: "Apps on watchOS primarily run in the foreground to limit the impact on system resources."
  Background refresh is "approximately four tasks per hour for each app with a complication on the active watch
  face", shared by all complications; inside a task "a maximum of four seconds of active CPU time", "15 seconds of total
  time", "No networking activity is allowed". https://developer.apple.com/documentation/watchkit/background-execution ,
  https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask ,
  https://developer.apple.com/videos/play/wwdc2020/10049/
- WatchConnectivity semantics: `updateApplicationContext` "replaces the previous dictionary" and is sent "when the
  opportunity arises"; `transferUserInfo` is "queued ... delivered in the order in which they were sent"; `sendMessage`
  from the watch "wakes up the corresponding iOS app in the background" but the reverse does not; `isReachable` on the
  watch is true only in the foreground or a high-priority background session.
  https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:) ,
  https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:) ,
  https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:) ,
  https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable
- Complication pushes: "50 transfers a day" with an active complication, 0 otherwise; WidgetKit complications get
  "up to 75 updates per day"; reloads are budget-free while the app is in the foreground.
  https://developer.apple.com/documentation/watchconnectivity/wcsession/remainingcomplicationuserinfotransfers ,
  https://developer.apple.com/documentation/widgetkit/converting-a-clockkit-app ,
  https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- Every `WKWatchConnectivityRefreshBackgroundTask` must be completed; "An uncompleted task consumes the background-task
  time budget ... which results in a crash." https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity
- Payload limits are undocumented (`payloadTooLarge`); community-measured 64 KiB for messages and context, 256 KiB for
  user info. https://zenn.dev/naoya_maeda/articles/d63504a860c36c (unofficial)
- Extended runtime session types (self care 10 min, mindfulness 1 h, physical therapy 1 h, smart alarm 30 min) must
  match "the app's intended use"; none fits location sharing. Watch GPS: "This is a fairly power expensive API".
  https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions ,
  https://nonstrict.eu/wwdcindex/wwdc2017/713/
- Always On: inactive frontmost apps get `TimelineView` updates "generally at the .minutes frequency"; design for
  wrist-down: "pause any animation and show the final state ... remove any subsecond updates".
  https://developer.apple.com/documentation/watchOS-Apps/updating-watchos-apps-with-timelines ,
  https://developer.apple.com/documentation/watchOS-Apps/designing-your-app-for-the-always-on-state
- SwiftUI: "It's important that body itself is as cheap as possible"; "reducing view values to only the data they
  actually depend on". https://developer.apple.com/videos/play/wwdc2023/10160/
- Battery and review: Series 9/10 "Up to 18 hours", Ultra 2 36 h (Apple); App Review 2.4.2 "Apps should not rapidly
  drain battery, generate excessive heat", 2.5.4 background modes only for intended purposes.
  https://www.apple.com/watch/compare/ , https://developer.apple.com/app-store/review/guidelines/
- watchOS memory: "The current limit, as of watchOS 3 is 30 megabytes per WatchKit application" (older figure; check
  `os_proc_available_memory`). https://nonstrict.eu/wwdcindex/wwdc2016/227/

## 4. Flutter at scale

- Rebuilds: "When setState() is called on a State object, all descendent widgets rebuild"; reuse identical child
  instances; `saveLayer()` "allocates an offscreen buffer" and is "particularly disruptive to rendering throughput";
  avoid `Opacity`, `Clip.antiAliasWithSaveLayer`, `ShaderMask`, `ColorFilter`, `ImageFilter`.
  https://docs.flutter.dev/perf/best-practices
- Budget: "16ms for building, and 16ms for rendering on a 60Hz display"; on 120 Hz "render frames in under 8ms
  (total)"; profile on "the slowest device that your users might reasonably use", always in profile mode on a device.
  https://docs.flutter.dev/perf/ui-performance
- `RepaintBoundary` helps when a subtree "repaints at different times than the surrounding parts of the tree"; verify
  with `debugRepaintRainbowEnabled`. https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html
- Images: a 4K image decoded is >30 MB; at 384x216 via `cacheWidth` about 330 KB. `ImageCache` defaults: "up to 1000
  images, and up to 100 MB". https://api.flutter.dev/flutter/widgets/Image-class.html ,
  https://api.flutter.dev/flutter/painting/ImageCache-class.html
- `compute` is "useful for operations that take longer than a few milliseconds"; `Isolate.run` returns results without
  copying. https://api.flutter.dev/flutter/foundation/compute.html , https://dart.dev/language/isolates
- Dart JSON decoding is about 8.8 ns/byte in AOT (roughly 9 ms per MB on a desktop, slower on phones).
  https://mrale.ph/talks/fnf2024
- Impeller: default on iOS and on Android API 29+ since 3.27; prefers Vulkan (1.1, Android 10+) with an OpenGL ES
  fallback; the Android opt-out meta-data is deprecated since 3.38. Known 2025-26 trouble: Vulkan disabled on "known
  bad exynos SoCs", MediaTek devices gated to GLES with +40-90 MB graphics memory, Mali crashes on some Galaxy A
  models, Adreno 702 raster 174-235 ms vs Skia 48-59 ms. https://docs.flutter.dev/perf/impeller ,
  https://github.com/flutter/engine/blob/main/impeller/docs/android.md ,
  https://github.com/flutter/flutter/pull/163236 , https://github.com/flutter/flutter/issues/193148 ,
  https://github.com/flutter/flutter/issues/192364
- Shader warm-up is Skia-only; Impeller compiles its shaders at engine build time.
  https://github.com/flutter/engine/blob/main/impeller/docs/faq.md
- Startup: TTID from `am start -W`; TTFD needs `reportFullyDrawn()`; Android vitals flags cold starts at 5 s, warm 2 s,
  hot 1.5 s; Android 12+ uses the SplashScreen API. https://developer.android.com/topic/performance/vitals/launch-time
- Deferred components depend on Play Feature Delivery and are not usable for a sideloaded APK without a custom
  manager. https://docs.flutter.dev/perf/deferred-components
- Size: `--split-debug-info` "can dramatically reduce code size"; measure with `--analyze-size` and
  `bundletool get-size`. https://docs.flutter.dev/perf/app-size
- `isLowRamDevice()` "generally means something with 1GB or less of RAM" (so 2-4 GB phones report false; use
  `totalMem`); `largeHeap`: "most applications should not need this amount of memory"; only
  `TRIM_MEMORY_UI_HIDDEN` and `TRIM_MEMORY_BACKGROUND` are delivered from Android 14.
  https://developer.android.com/reference/android/app/ActivityManager ,
  https://developer.android.com/topic/performance/memory/manage-app-memory
- flutter_map: markers are culled and "the marker child is not built when culled" (needs explicit width/height);
  built-in tile caching since v8.2 with "a 1 GB (soft) limit"; `panBuffer` "typically ... zero or one".
  https://docs.fleaflet.dev/layers/marker-layer , https://docs.fleaflet.dev/layers/tile-layer/built-in-caching
- 120 Hz: the engine never calls `Surface.setFrameRate()`; OEM heuristics may hold Flutter apps at 60 Hz;
  `flutter_displaymode` is "ineffective on devices with LTPO panels" (the Fold 4 is LTPO).
  https://github.com/flutter/flutter/issues/160952 , https://pub.dev/packages/flutter_displaymode
- Foldables: "An app stops and restarts as it transitions from one screen to another when a device folds or unfolds"
  unless `configChanges` covers it (Flutter's template does); Tier 3 adaptive quality requires state retention across
  folding; test target "Foldable (841x701 dp)"; never lock orientation (letterboxing) and use `MediaQuery` for window
  size; `DisplayFeatureSubScreen` keeps dialogs off the hinge. https://developer.android.com/guide/topics/large-screens/learn-about-foldables ,
  https://developer.android.com/docs/quality-guidelines/adaptive-app-quality/tier-3 ,
  https://docs.flutter.dev/ui/adaptive-responsive/large-screens ,
  https://api.flutter.dev/flutter/widgets/MediaQueryData/displayFeatures.html

## 5. Server side

- Ingest: "loading a large number of rows using COPY is almost always faster than using INSERT, even if PREPARE is used
  and multiple insertions are batched." Timescale's benchmark: binary COPY "at least 3.6x" faster at large batches but
  "Both COPY variants perform poorly with batches of 1,000"; prepared `INSERT ... UNNEST` is "surprisingly competitive"
  up to 10k rows; WAL 62 MB vs 109 MB per million rows. https://www.postgresql.org/docs/current/populate.html ,
  https://www.tigerdata.com/blog/benchmarking-postgresql-batch-ingest
- pgx: "By default pgx uses the extended protocol and automatically prepares and caches prepared statements"; pgxpool
  MaxConns defaults to max(4, NumCPU). Connection rule of thumb: ((core_count * 2) + effective_spindle_count).
  https://pkg.go.dev/github.com/jackc/pgx/v5 , https://wiki.postgresql.org/wiki/Number_Of_Database_Connections
- TimescaleDB: chunk interval so "the indexes of chunks currently being ingested into fit within 25% of main memory";
  compression batches of ~1,000 rows per segment, "90%+ space savings" claimed; SkipScan makes latest-per-device
  O(K log N) (4.6 ms vs 3,912 ms on 23.3M rows); a separate latest table is the pattern for the hot path but "Insert and
  Update performance will be impacted"; retention drops whole chunks. https://www.tigerdata.com/docs/learn/hypertables/sizing-hypertable-chunks ,
  https://www.tigerdata.com/blog/skipscan-in-timescaledb-why-distinct-was-slow-how-we-built-it-and-how-you-can-use-it ,
  https://www.tigerdata.com/blog/select-the-most-recent-record-of-many-items-with-postgresql ,
  https://www.tigerdata.com/docs/use-timescale/latest/data-retention/about-data-retention
- WebSocket fan-out: the gorilla hub drops a slow client with a non-blocking send (`default: close(client.send)`),
  uses writeWait 10 s, pongWait 60 s, pingPeriod 54 s, and drains the queue into one frame; "Connections support one
  concurrent reader and one concurrent writer". Discord cut gateway traffic ~40% by sending "only ... the delta of
  what's changed since the last update". https://raw.githubusercontent.com/gorilla/websocket/main/examples/chat/client.go ,
  https://pkg.go.dev/github.com/gorilla/websocket ,
  https://discord.com/blog/how-discord-reduced-websocket-traffic-by-40-percent
- Mobile sockets: iOS suspends backgrounded apps and the socket dies with them; a push is the supported way back.
  https://docs.rs/koan-server/0.45.1/koan_server/push/
- Push: FCM normal priority is deferred in Doze, high priority "wake[s] a sleeping device when necessary" and is
  deprioritised when it does not produce a visible notification (7-day window); at most 4 collapse keys per token.
  APNs: priority 10 "immediately", 5 "based on power considerations"; for `background` pushes "Always use priority 5";
  "don't try to send more than two or three per hour"; `apns-collapse-id` up to 64 bytes; payload 4,096 bytes.
  UnifiedPush payloads are 1-4,096 bytes encrypted. https://firebase.google.com/docs/cloud-messaging/android/message-priority ,
  https://firebase.google.com/docs/cloud-messaging/customize-messages/collapsible-message-types ,
  https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns ,
  https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app ,
  https://unifiedpush.org/developers/spec/android/
- Go: `GOMEMLIMIT` with "5-10% of headroom" in containers; "doubling GOGC will double heap memory overheads and
  roughly halve GC CPU cost"; Go 1.25 derives GOMAXPROCS from the cgroup CPU limit; PGO "improves performance by around
  2-14%"; `encoding/json/v2` unmarshal "up to 10x" faster (GA in Go 1.27); `http.Server` needs explicit Read/Write/Idle
  timeouts and hijacked WebSocket connections need their own per-write deadlines; benchstat wants "at least 10, ideally
  20" runs. https://go.dev/doc/gc-guide , https://go.dev/blog/container-aware-gomaxprocs , https://go.dev/doc/pgo ,
  https://go.dev/blog/jsonv2-exp , https://blog.cloudflare.com/the-complete-guide-to-golang-net-http-timeouts/ ,
  https://pkg.go.dev/golang.org/x/perf/cmd/benchstat
- Postgres on small boxes: shared_buffers about 1/4 of RAM (closer to 15% on tiny boxes), effective_cache_size 1/2 to
  3/4, work_mem is per sort; `synchronous_commit=off` gives thousands of commits/s with no corruption risk, only lost
  recent commits; insert-only tables need a lower `autovacuum_vacuum_insert_scale_factor`; `timescaledb-tune` takes
  `--memory` and `--cpus`. https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server ,
  https://www.postgresql.org/docs/current/runtime-config-autovacuum.html , https://github.com/timescale/timescaledb-tune

## 6. Measurement culture and store vitals

- Android vitals thresholds: user-perceived crash rate 1.09% (8% per phone model, 4% per watch model), ANR 0.47% (8% /
  5%), excessive partial wake locks 5% of sessions (wake locks of 2 h or more per 24 h in the background; "Android
  vitals exempts wake locks created by audio, location, and JobScheduler user-initiated APIs"), excessive wakeups
  >10 AlarmManager wakeups per hour, stuck wake lock = one hour-long background wake lock in 24 h, background Wi-Fi
  scans >4/h, background network >50 MB/day, slow cold start 5 s (warm 2 s, hot 1 s), slow frames >50% over 16 ms,
  frozen frames >0.1% over 700 ms. "Play may reduce the visibility of your title." Memory becomes a core vital with
  visibility impact "starting from February 2027". https://developer.android.com/topic/performance/vitals ,
  https://developer.android.com/topic/performance/vitals/wakelock , https://developer.android.com/topic/performance/vitals/wakeup ,
  https://developer.android.com/google/play/vitals/stuck-wakelock , https://developer.android.com/google/play/vitals/bg-network-usage ,
  https://support.google.com/googleplay/android-developer/answer/9844486 , https://developer.android.com/google/play/vitals/memory-usage
- Wear watch-face battery vital: sessions >4.44%/hour are excessive; "aim for battery usage under 3.2% per hour".
  https://developer.android.com/google/play/vitals/excessive-battery-usage
- Apple: hangs are reported when the main run loop is unresponsive >250 ms; hitch rate "at or below 10 ms/s is good";
  launch "within 400 milliseconds" to first frame; Organizer alerts when a version "regresses 75 percent or more
  compared to the average of the previous four app versions"; disk-write exception at >1 GB/24 h.
  https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app ,
  https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app ,
  https://developer.apple.com/videos/play/wwdc2019/423/ ,
  https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-shipping-app
- Frame budgets: 16.7 ms at 60 Hz, 11.1 ms at 90 Hz, 8.3 ms at 120 Hz; RAIL: respond within 100 ms, animate in 10 ms
  (16 ms ceiling), idle chunks under 50 ms, load under 5 s. https://developer.android.com/topic/performance/vitals/render ,
  https://web.dev/articles/rail
- CI gates: Macrobenchmark `StartupTimingMetric` and `FrameTimingMetric` (P50/P90/P95/P99), physical devices only
  ("returns errors when attempting to measure an emulator"), "always focus on median values"; Flutter
  `integration_test` `traceAction` + `TimelineSummary` with `90th_percentile_frame_build_time_millis`,
  `missed_frame_build_budget_count`; `bundletool get-size total`; Lighthouse CI assertions with median of 3 runs;
  size-limit "comments and rejects pull requests". https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview ,
  https://developer.android.com/topic/performance/benchmarking/benchmarking-in-ci ,
  https://docs.flutter.dev/cookbook/testing/integration/profiling , https://developer.android.com/tools/bundletool ,
  https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/configuration.md , https://github.com/ai/size-limit
- Battery measurement: `adb shell dumpsys batterystats --reset`, soak, dump and Battery Historian (unmaintained but
  works); Power Profiler rails on Pixel 6+; Xcode Organizer background battery per 24 h and MetricKit
  `LocationActivityTimeMetric`. https://developer.android.com/topic/performance/power/setup-battery-historian ,
  https://developer.android.com/studio/profile/power-profiler ,
  https://developer.apple.com/documentation/xcode/analyzing-your-app-s-battery-use
- Memory: Android Go edition needs 2 GB from Android 13; "build for billions" asks "PSS of the app's RAM usage should not
  exceed 90MB"; Flutter DevTools memory view samples Dart heap, native and RSS every 500 ms.
  https://developer.android.com/guide/topics/androidgo ,
  https://developer.android.com/docs/quality-guidelines/build-for-billions/device-capacity ,
  https://docs.flutter.dev/tools/devtools/memory
- Store checks: Play pre-launch report crawls "for several minutes" on phones, tablets and Wear; core app quality
  `App_Startup_Time` wants onscreen feedback within two seconds and lists "Keeping the GPS powered on" as a poor use of
  background services; adaptive quality tiers test on a 841x701 dp foldable.
  https://support.google.com/googleplay/android-developer/answer/9842757 ,
  https://developer.android.com/docs/quality-guidelines/core-app-quality ,
  https://developer.android.com/docs/quality-guidelines/large-screen-app-quality

## Key numbers we build on

| Fact | Value | Source |
|---|---|---|
| Life360 battery budget | about 10% per 24 h | support.life360.com (self-reported) |
| Tiered tracker drain | <1%/h still, 2-3%/h walking, 5-6%/h driving | blog.corvusgps.com (vendor) |
| iOS SLC | 500 m, at most every 5 min | developer.apple.com startmonitoringsignificantlocationchanges() |
| iOS regions / CLMonitor conditions | 20 | developer.apple.com startmonitoring(for:) |
| Android geofences; min radius; latency | 100; 100-150 m; 2-6 min | developer.android.com geofencing |
| Android bg location without FGS | a few fixes per hour | developer.android.com background-location-limits |
| Doze while-idle alarm cap | 1 per 9 min per app | developer.android.com doze-standby |
| Batching example | 10 min interval + 60 min max delay = 1 wake/h | developer.android.com location/battery/optimize |
| Android vitals excessive wakeups | >10/h | developer.android.com vitals/wakeup |
| Android vitals bg network | >50 MB/day | developer.android.com bg-network-usage |
| Android vitals cold start | 5 s (warm 2 s, hot 1 s) | support.google.com 9844486 |
| Android vitals frames | >50% slow (>16 ms); >0.1% frozen (>700 ms) | support.google.com 9844486 |
| Wear battery "good" | <3.2%/h (excessive >4.44%/h) | developer.android.com excessive-battery-usage |
| Data Layer item | 100 KB max; non-urgent up to 30 min | developer.android.com data-items |
| Tile refresh floor | 1/min; recommended >= 2 h or push | developer.android.com TileBuilders, apps/power |
| Complication period floor | 300 s (0 = push) | android-developers.googleblog.com 2025/08 |
| watchOS bg refresh | ~4/h with an active complication; 4 s CPU, 15 s wall, no network | developer.apple.com wkapplicationrefreshbackgroundtask, WWDC20 10049 |
| WC complication transfers | 50/day; WidgetKit reloads 75/day | developer.apple.com remainingcomplicationuserinfotransfers |
| watchOS app memory | 30 MB (watchOS 3 figure) | WWDC16 227 |
| iOS hang / hitch / launch | 250 ms / 10 ms per s / 400 ms | developer.apple.com xcode docs, WWDC19 423 |
| Frame budget | 16.7 / 11.1 / 8.3 ms at 60 / 90 / 120 Hz | developer.android.com vitals/render |
| Flutter ImageCache default | 1000 images, 100 MB | api.flutter.dev ImageCache |
| Dart JSON decode | ~8.8 ns per byte (AOT) | mrale.ph fnf2024 |
| Impeller GLES fallback cost | +40-90 MB graphics memory | github.com/flutter/flutter/issues/193148 |
| COPY vs INSERT | >=3.6x at large batches; poor at 1,000-row batches | tigerdata.com batch-ingest benchmark |
| pgxpool default MaxConns | max(4, NumCPU) | pkg.go.dev pgxpool |
| APNs background pushes | 2-3 per hour, priority 5 | developer.apple.com pushing-background-updates |
| FCM collapse keys per token | 4 | firebase.google.com collapsible-message-types |
| GOMEMLIMIT headroom | 5-10% under the container limit | go.dev/doc/gc-guide |
| benchstat | >=10 runs, ideally 20 | pkg.go.dev benchstat |
| Play size warning | 200 MB on mobile data | support.google.com 9859372 |
