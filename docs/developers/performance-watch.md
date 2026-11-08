# Wear OS performance

What was changed to make the Orbitly watch app smoother and lighter on the battery, what is still unmeasured, and how to measure it on a real Galaxy Watch Ultra.

**Honesty first.** No watch was available while this was written. The findings below come from reading the code and from what compiles and passes unit tests. Nothing here was timed on a device. Every "faster" claim is a design argument until you run the measurements in the last section.

## What the audit found, and what changed

| Area | Before | Now |
| --- | --- | --- |
| Reading the saved snapshot at start | Synchronous disk read and JSON parse in the view model constructor, on the main thread, before the first frame | Read and parsed on a background thread. The screen shows nothing for that moment instead of a wrong "Sign in on your phone" message |
| Every push from the phone | Parsed, written to disk, and the tile and complication were redrawn, even when the text was identical (also on every app resume) | An identical item (same text, same login) is dropped with one string comparison. No parse, no disk write, no redraw |
| Parsing on resume | `syncNow` parsed on the main thread | Runs on the default background dispatcher |
| Last known location | Read on the main thread on each resume | Background thread |
| Tile request | Disk and parse on the main thread on the first call | Built on a worker thread |
| Complication request | Same | Built on the default dispatcher |
| SOS hold button | The whole list was recomposed every 50 ms while the finger was down | The list recomposes only when the phase or the countdown second changes. The progress ring reads its value while drawing, so only that canvas redraws |
| Compass | Sensor kept registered while the app was in the background with the screen on; whole screen recomposed 5 times a second | Registered only while the app is resumed and not in ambient mode, sampling requested at 5 Hz, unregistered on pause. Low-pass filter with a 1.5 degree dead band. The arrow reads the heading while drawing, so only the arrow redraws, and not at all when the watch is held still |
| List rows | No keys, rows rebuilt on every recomposition, second line string built per row per recomposition | Stable keys (ids, made unique when the snapshot is parsed so duplicate ids cannot crash a list), rows remembered per snapshot and location, second line built once |
| Compose stability | `List` fields make the model classes "unstable" | `stability_config.conf` marks the immutable model classes as stable so unchanged screens are skipped |
| Avatars | Clip plus background | One shape-aware background. Avatars were already initials only; there is no image loading in the app |
| Release build | Minified and resource-shrunk | Also `isDebuggable = false` stated explicitly, `androidx.profileinstaller` added, a hand-written baseline profile under `wear/app/src/main/baseline-prof.txt` |
| Manifest | Only the watch feature | GPS, compass and accelerometer declared `required=false` so Play does not hide the app from a watch that lacks one |

## Things checked that were already right

- No polling anywhere. The app is woken only by the Wearable Data Layer when the phone writes the snapshot or connects.
- No foreground service and no wake lock taken by the app. `WAKE_LOCK` is declared only because `AmbientLifecycleObserver` requires the permission.
- The only continuous sensor is the rotation vector on the Direction screen, now bound to the resumed lifecycle.
- Ambient mode: `AmbientLifecycleObserver` is registered; in ambient the theme switches to black with outlined chips, the home screen shows only the nearest person, the compass sensor stops, and the vignette and scroll indicator are not drawn. The only moving thing in ambient is the system clock.
- Hardware buttons: no key handler is installed, so the Quick button and the power button keep their system behavior. Rotary and touch-bezel scrolling is handled by `ScalingLazyColumn` itself.
- Complication: `UPDATE_PERIOD_SECONDS = 0`, content is pushed after a new snapshot. Tile: freshness interval 0, redrawn on a new snapshot and whenever the system shows it.
- No Application class and no dependency injection: nothing runs before the activity, so there is no Application start-up cost to remove.
- `minSdk` 30 (Wear OS 3 and up), `targetSdk` 35.

## Build result

`cd wear && ./gradlew --no-daemon :app:testDebugUnitTest :app:assembleRelease` (in the Flutter image): 36 unit tests, 0 failures; the unsigned release APK is 3.2 MB and contains `assets/dexopt/baseline.prof` (7 KB) and `baseline.profm`, plus the profileinstaller version marker. Whether the profile actually speeds up start on the Ultra is unmeasured.

Known and left alone: Android lint (non-fatal here, `abortOnError = false`) flags `BIND_LISTENER` on `DataLayerService` as deprecated because it wakes the service for every Data Layer event of this app. Switching to filtered `DATA_CHANGED` and `MESSAGE_RECEIVED` filters would save a few wake-ups, but connect and disconnect events need the broad listener, and a wrong filter would silently stop all phone pushes, which cannot be tested without a watch.

## The phone side

`WatchBridge` (`app/lib/services/watch/watch_bridge.dart`) already protects the watch:

- At most one publish per 5 seconds (`minInterval`); newer state replaces a waiting one.
- A content hash skips a publish when nothing visible changed.
- Snapshots are capped at 100 KB, 15 people and 5 alerts; the watch rejects larger ones.
- A keep-alive publish every 10 minutes while a watch is connected. A forced publish also follows each command (limited by the per-command cooldowns, 2 s, SOS 60 s).

Not changed: items are sent `urgent`, so the watch is woken right away. That is right for people moving on a map, but if battery turns out to be an issue the first thing to try is non-urgent puts for the 10 minute keep-alive.

## Baseline profile

A baseline profile tells Android which classes and methods to compile ahead of time at install, so the first launch and the first scroll do not run in the slow interpreter.

- `wear/app/src/main/baseline-prof.txt` is hand-written and covers the app's own start-up and screen code. AGP packs it into the release APK as `assets/dexopt/baseline.prof`, and `androidx.profileinstaller` installs it on first run (and when the system does not do it itself). Compose and Wear Compose libraries ship their own profiles inside their AARs, and these are merged in.
- A hand-written profile is a fallback. A generated one is better because it lists exactly what ran. Generating needs a watch or a Wear emulator, which this build environment does not have; see "Generate a real profile" below.

## How to measure on the Galaxy Watch Ultra

Connect with Wireless debugging (Developer options, ADB debugging, Debug over Wi-Fi) and `adb pair` / `adb connect`. Use the release APK; a debug build is much slower and tells you nothing.

1. Cold start time:
   ```
   adb shell am force-stop app.openfamily
   adb shell am start-activity -W -n app.openfamily/app.openfamily.wear.MainActivity
   ```
   Read `TotalTime` and `WaitTime`. Run it 10 times, drop the first, take the median. Do this once with the profile compiled and once without:
   ```
   adb shell cmd package compile -m speed-profile -f app.openfamily     # with profile
   adb shell cmd package compile --reset app.openfamily                 # back to the installed state
   ```
2. Dropped frames while scrolling the People list (open it, then scroll for 10 seconds):
   ```
   adb shell dumpsys gfxinfo app.openfamily reset
   # ... scroll ...
   adb shell dumpsys gfxinfo app.openfamily framestats
   ```
   Look at "Janky frames" and the 90th, 95th and 99th percentile frame times. On a 60 Hz AMOLED the budget is 16.6 ms.
3. SOS hold: the same `gfxinfo` while holding the SOS button for 1.5 s. Before this change the whole tree was recomposed every 50 ms; the draw-only ring should show far fewer long frames.
4. Compass: with `adb shell dumpsys sensorservice` check that the rotation vector has an active connection only while Direction is on screen and the screen is on (nothing after you press the power button).
5. Traces: record a Perfetto trace (`adb shell perfetto -o /data/misc/perfetto-traces/t.pb -t 20s sched freq idle am wm gfx view binder_driver ...` or the Perfetto UI over USB/Wi-Fi), open the app, scroll, then look at the main thread for `Choreographer#doFrame` over 16 ms and for any `JSONObject` or `SharedPreferences` slice on the main thread (there should be none now). Android Studio's Profiler (CPU and Energy, with the watch selected) shows the same without command lines.
6. Battery: `adb shell dumpsys batterystats --reset`, use the watch normally for a few hours, then `adb shell dumpsys batterystats app.openfamily`. Expect almost nothing; if there is wake-up time, check the Data Layer push rate in `adb logcat -s WearableService`.
7. Large text: Settings, Display, Font size at the largest step, then open every screen once. Chips are limited to 1 to 3 lines and the list scrolls, so overflow should only clip a long name.

## Generate a real profile

The Gradle Baseline Profile plugin needs a device. On a machine with a Wear OS emulator or a watch connected, add a `com.android.test` module that drives the app (open, scroll People, open a person, open Direction) with Macrobenchmark's `BaselineProfileRule` and run `./gradlew :app:generateBaselineProfile`. Replace or merge the output into `wear/app/src/main/baseline-prof.txt`. The plugin was not added to the build here because a build that cannot run its generator would be a broken task, not a feature.

## Tests added

`wear/app/src/test/kotlin/app/openfamily/wear/PerfLogicTest.kt`: duplicate-push dropping, heading filter (wrap-around at north, dead band, convergence), unique list ids after parsing, row text, oversized snapshot rejection, and the SOS hold timing in 50 ms steps. They run in `./gradlew :app:testDebugUnitTest` in `wear/`.

## Not done, on purpose

- Moving from Wear Compose Material 2 to Material 3 (`ScreenScaffold`, `AppScaffold`, `EdgeButton`). It is a visual redesign and needs real-watch review; the M2 `Scaffold` plus `ScalingLazyColumn` already handle round screens, the clock and the scroll indicator. Worth doing after the v1.0 demos.
- A tile age that updates itself. The "2 min" text is drawn when the tile is requested, and the system requests it again whenever the tile is shown.
