# Performance and memory on low-RAM phones

How the app adapts to phones with 2 GB to 16 GB of RAM: device tiers, memory-pressure handling, APK variants and size, and how to test on real phones.

Scope: release 0.25 work to make the app comfortable on 2 GB and 3 GB phones while keeping the full app on 6 GB and
up. Build size, memory tiers, memory-pressure handling, and what was deliberately not changed.

**Important: nothing here was measured on a phone.** Numbers come from (a) a Gradle release build of the APK in
Docker on a build server and (b) the Flutter test VM on that server, which is a desktop-class process with in-memory
stores and no platform channels. They show relative effects and exact sizes of files, not what a 2 GB phone feels. The
section "Testing on real phones" lists what to run on real hardware; it has not been run.

## What the platform guidance says (and what we took from it)

| Source | Used for |
|---|---|
| [Android: manage app memory](https://developer.android.com/topic/performance/memory/manage-app-memory) | R8 shrinking lowers RAM as well as size; avoid package-wide keep rules; from Android 14 only `TRIM_MEMORY_UI_HIDDEN` and `TRIM_MEMORY_BACKGROUND` are delivered, so those two drive the trim policy; bitmaps are the largest objects, release image caches when the UI is hidden; `ActivityManager.getMemoryInfo` for total/available memory; do not leave services running without need; LMK kills cached processes first |
| [Android: memory overview page](https://developer.android.com/topic/performance/memory) | `dumpsys meminfo`, Perfetto heap explorer, Android vitals (LMK rate) as the production signal |
| [Flutter: performance best practices](https://docs.flutter.dev/perf/best-practices) | build lists lazily, avoid `saveLayer`/`Opacity`/clip-heavy trees, measure in profile mode on the lowest-end device |
| [Flutter: measuring and reducing app size](https://docs.flutter.dev/perf/app-size) | `--analyze-size`, `--split-debug-info`, remove unused resources, tree-shaking |
| [Android: optimize battery for background tasks](https://developer.android.com/develop/background-work/background-tasks/optimize-battery) | batch work into one task, avoid needless wake-ups |

Not read in full (the fetch returned only a title or nothing useful): Apple's jetsam documentation page, Flutter's
Impeller and Dart-isolate pages, and Android's location-battery page. The iOS section below therefore rests on general
knowledge of jetsam (per-process limits, background apps killed first) and on Flutter's own
`didHaveMemoryPressure` hook, not on a fresh read of Apple's text. Treat those parts as unverified.

## Device tiers

Decided once at start-up in `app/lib/services/perf/device_tier.dart` from `ActivityManager.MemoryInfo.totalMem`
(Android) or `ProcessInfo.physicalMemory` (iOS; Swift unverified, see below). `isLowRamDevice()` forces Lite.

| Tier | Marketing RAM | Reported-RAM rule | Notes |
|---|---|---|---|
| Lite | under 4 GB (2, 3 GB) | `isLowRamDevice` or reported total under 3500 MiB | |
| Standard | 4 GB up to under 6 GB | 3500 to under 5300 MiB (also: memory unknown) | |
| Full | 6 GB and more (6, 8, 12, 16) | 5300 MiB and up | |

Phones report less than they are sold with (kernel, GPU and modem reserve), so the cut-offs sit below the marketing
sizes: a "4 GB" phone usually reports around 3.7 GiB. The cut-offs are a judgement from typical reported values, not
a measurement of any specific phone; `PerfProfile.memory` keeps what the phone reported (not yet shown on a screen).

`PerfProfile` (`perf_profile.dart`) holds every value that scales with the tier:

| Setting | Lite | Standard | Full |
|---|---|---|---|
| Decoded-image cache | 24 MB / 60 images | 48 MB / 150 | 100 MB / 1000 (Flutter default) |
| Map tiles in memory / on disk | 3 MB / 25 MB | 6 MB / 50 MB | 10 MB / 50 MB (as before) |
| Tile download concurrency | 1 | 2 | 2 |
| Track points kept per member (stored and in memory, Private circles) | 500 | 2000 | 6000 (as before) |
| Catch-up page size (items per request) | 50 | 100 | 200 (as before) |
| Animation scale, blurred marker shadows | 0.6x, off | 1x, on | 1x, on |
| "Last seen" refresh tick | 60 s | 30 s | 30 s |
| Keep the background isolate warm | no | no | yes (flag; see below) |
| On-device trip/drive/week processing | never | allowed | allowed |

Everything on the Full row equals the values before tiers existed, so a 6 GB+ phone behaves as in 0.24. Two flags are
declared but only partly consumed: `keepBackgroundIsolateWarm` has no reader yet (the background location isolate is
owned by the vendored `background_locator_2` plugin), and `allowOnDeviceProcessing` is the single place to ask before
running heavy processing locally; the processing-lanes code still decides by consent first.

**Direction taken for history:** the phone keeps a working set (latest fix per member plus a few hundred recent
points on Lite) and older history is meant to be fetched on demand. For Plain circles the day view is built from a server request (`HistoryService.fetchDay`). For Private circles the server holds only ciphertext, so the phone's copy is the only readable
history; shrinking the cap on Lite means older points are dropped on the next write (the cap is applied when a track
is written). That is a deliberate trade for 2 GB phones and is why Standard and Full keep far more.

## Memory pressure

`memory_pressure.dart` (`MemoryPressureGuard`) reacts to Flutter's `didHaveMemoryPressure` and to Android
`onTrimMemory` forwarded by `MainActivity` over the `app.openfamily/device` channel:

* every signal at or above `RUNNING_LOW`: clear the image cache and live images;
* `UI_HIDDEN` (20): images only; `BACKGROUND` (40) and above, or the legacy `RUNNING_CRITICAL`: also run the
  registered trimmers: write out pending Private-circle points and last positions (never dropped), and free the encoded
  avatar photos (fetched again when needed).

Trimmers are registered with `addTrimmer`; a trimmer that throws does not stop the others. Nothing in a trimmer may lose
data. Not done: releasing the vector map's tile memory on background (the `vector_map_tiles` layer exposes no hook;
its memory cache is capped per tier instead), and dropping track lists held by individual screens (not audited screen by
screen; see the leak section).

## Build size

**No APK size was measured.** The Docker release builds (`--analyze-size`, arm64, arm, combined) were started but never finished: the host was overloaded and the Gradle step stalled, then all heavy jobs were stopped. The size claims below (for example "about 40 percent smaller" for a single-ABI APK) are therefore expectations from the native-library split, not numbers; re-run `flutter build apk --release --analyze-size --target-platform android-arm64` and record the baseline. What changed in the build:

* R8 minify and resource shrinking were already on for release (`isMinifyEnabled`, `isShrinkResources`, with
  `proguard-android-optimize.txt`). The keep rules in `proguard-rules.pro` are package-wide (`app.openfamily.**`,
  `com.google.crypto.tink.**`, `yukams.app.background_locator_2.**`, GMS location). Android's guidance warns that these
  stop R8 from shrinking those packages. They were left alone: narrowing them without a device to run the release build
  on (Keystore channel, background locator callbacks, Tink) risks a crash that only shows on a phone. This is the
  biggest unverified opportunity.
* The release workflow now builds three APKs from the same source and the **same versionCode**: the combined
  `orbitly-<v>.apk` (arm64 + armeabi-v7a), `orbitly-<v>-arm64-v8a.apk` and `orbitly-<v>-armeabi-v7a.apk`, plus the AAB.
  `flutter build apk --split-per-abi` was **not** used: Flutter's Gradle plugin then adds `1000 x ABI` to the version code
  (checked in `FlutterPlugin.kt`: arm 1, arm64 2), which would make an arm64 split newer than the next combined release
  and block updates. Building each target separately keeps one code for all three files.
* `/app.apk` and the admin download pick the combined APK first (it installs everywhere, including 32-bit systems that
  are common on 2 GB phones), then arm64-v8a, then armeabi-v7a (`pickAPKAsset` in `backend/internal/apkrelease`, with a
  test). Obtainium, which takes the first `.apk` of a release, may now ask which file to track; set its ABI filter
  or the regular expression `orbitly-[0-9.]+\.apk$` for the combined one.
* `scripts/apk-size-budget.sh <apk>` compares an APK with `scripts/apk-size-baseline.txt` and fails above +5 percent.
  In CI it runs after the arm64 build as a warning only (it never fails the release). Record the first baseline from a
  release build with `scripts/apk-size-budget.sh <apk> --record`.

Considered and not done:

* `--obfuscate --split-debug-info`: the app prints `runtimeType` names in Diagnostics and the Performance screen and in
  self-test messages, and obfuscation would turn them into gibberish; whether persisted enum names survive it was not
  verified. The size win is a small part of the Dart snapshot.
* Locale stripping (`localeFilters`): the app is English only, but library strings (for example the system biometric
  dialog text) are translated and would turn English on other-language phones.
* Deferred components: the app has no feature large enough to justify the Play-only complexity.
* Dependency removal: all 25 direct dependencies are imported by `lib/` (checked with a grep per package). The heaviest
  families are the map stack (`flutter_map`, `vector_map_tiles`) and `cryptography` (pure Dart); there is no lighter drop-in.
* Fonts/assets: `assets/` is 200 KB in total; the app uses the Material icon font, which Flutter tree-shakes.

## Startup

`main()` already reads the stored settings in parallel and defers screens. Added: `PerfProfile.init()` runs in that same
`Future.wait` (one small platform call, no extra step before the first frame) so caches are sized before the first
screen. The memory-pressure guard is installed right before `runApp`. Nothing was added to the critical path that
touches storage or the network.

## iOS

Shared in Dart: tiers, `PerfProfile`, image cache sizing, `didHaveMemoryPressure` (Flutter forwards iOS memory
warnings to it). Added in Swift (`ios/Runner/AppDelegate.swift`): a `memoryInfo` method on `app.openfamily/device`
returning `ProcessInfo.physicalMemory` and `os_proc_available_memory()`. **Not compiled or run here; verify on a Mac
before release.** The tier thresholds are the same numbers; iPhones report their physical RAM (an iPhone with 4 GB reports
about 3.7 to 4 GB), so the Lite/Standard boundary on iOS is the least certain part.

## Battery and CPU

Location reporting is already adaptive (`tracking_cadence.dart`: stationary background reports every 60 s, idle every
3 minutes, faster only while driving). It was reviewed against Android's guidance on batching and wake-ups and not
changed: the outbox already batches uploads, and the Private history writes are write-behind (one rewrite per 4 s
instead of per point). The tier scales the staleness timer only.

## Measured in the test VM (host heavily loaded, single run, NOT a phone)

`memory_footprint_bench_test.dart`: 6000 points written per member, then a 300-item catch-up. Process RSS in MB:

| Tier | Points kept | Catch-up page | RSS start | after catch-up | max RSS |
|---|---|---|---|---|---|
| Lite | 500 | 50 | 192 | 214 | 219 |
| Full | 6000 | 200 | 191 | 203 | 208 |

This does not show Lite using less memory: RSS in a long-lived VM is dominated by the harness and the garbage
collector's timing, and 6000 points are well under 1 MB of Dart objects. The reliable, deterministic effect is the
count of points kept and stored (500 vs 6000), and fewer items per request. Smaller pages trade more requests for lower
peak per request; the table suggests no memory win at 300 items. A Standard run was lost when two runs wrote to the same
file. The 50-cycle screen leak test (`screen_leak_test.dart`, leak_tracker, server settings and privacy policy screens) passes in the test VM; it ignores the image cache's own stream handles. Only those two screens are covered, not the map or chat screens. The
"before vs after" comparison and the 100-member marker benchmark were not done.

## Reproducing

Unit tests: `flutter test test/perf/device_tier_test.dart` (tier mapping, profile values, memory-pressure behaviour).
Benchmark (one tier per process for clean numbers):
`flutter test test/perf/memory_footprint_bench_test.dart --plain-name 'lite:'` (prints `MEMMETRIC`).

## Testing on real phones (not run)

```
adb shell dumpsys meminfo app.orbitly            # PSS by category; run before/after 30 min of use
adb shell am send-trim-memory app.orbitly BACKGROUND   # then check Diagnostics / dumpsys meminfo
adb shell am send-trim-memory app.orbitly RUNNING_CRITICAL
adb shell cat /proc/$(adb shell pidof app.orbitly)/status | grep -E "VmRSS|RssAnon|VmSwap"
adb shell am kill app.orbitly                    # process death, then cold start
```

* Emulator: create an AVD with 2 GB RAM (`hw.ramSize=2048`) and, if available, an Android Go system image (it reports `isLowRamDevice`). Use `adb shell dumpsys meminfo` to see the total; there is no on-screen tier readout yet.
* Developer options: turn on "Don't keep activities" and set "Background process limit" to "At most 2 processes" to force
  restarts and trims.
* DevTools Memory view (profile build) and Perfetto (`perfetto.dev`, heap dump explorer) for Dart and native heap.
* Production signal: Android vitals "Memory usage" and the low-memory-kill rate.
* Success looks like: no OOM or LMK kill of the foreground app during a 30-minute session with a large Private circle on
  a 2 GB device, and a cold start to first frame comparable with a 6 GB phone.
