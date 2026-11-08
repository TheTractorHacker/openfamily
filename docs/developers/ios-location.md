# iOS background location

How the iPhone app lowers its location cost when the phone is not moving: the states, thresholds and Apple sources behind them, what CI proves, and the test plan for a real iPhone.

Status: the Dart side is unit-tested; the Objective-C side was written without a Mac and has
not been compiled or run yet. The first macOS CI run is the compile proof (see
[What CI must show](#what-ci-must-show)); the first iPhone day is the behavior proof.

## Before and after

Before (up to v0.25): `startUpdatingLocation` with `kCLLocationAccuracyBest`, a 50 m distance
filter and `pausesLocationUpdatesAutomatically = NO`, all day. The adaptive cadence was
Android only: the iOS plugin did not implement `updateLocationRequest`, and the background
isolate could not reach the plugin channel at all (the plugin registered its channel only on
the UI engine). So a phone lying on a desk kept the GPS-class request running around the clock.

Now: the same cadence policy as Android (`app/lib/services/tracking_cadence.dart`) decides the
tier from speed, stillness, live boost and SOS, and `app/lib/services/ios_location_profile.dart`
maps every tier to a Core Location request. The plugin
(`app/packages/background_locator_2/ios/Classes/BackgroundLocatorPlugin.m`) only applies it.

## States and requests

| Cadence tier | Entered when | iOS accuracy | Distance filter | Activity type |
| --- | --- | --- | --- | --- |
| SOS | SOS burst (foreground reporter) | best | none | other navigation |
| boosted | someone watches live | best | 5 m | other navigation |
| driving | smoothed speed >= 3 m/s twice, or one fix >= 8 m/s | best | 10 m | automotive navigation |
| driving, battery < 15% | as above, not charging | nearest ten meters | 25 m | automotive navigation |
| walking | smoothed speed >= 0.8 m/s | nearest ten meters | 15 m (25 m below 15% battery) | fitness |
| stationary ("slow") | default; registration; every native wake-up | nearest ten meters | 25 m | other |
| idle ("still") | 10 min within 60 m of the same spot | three kilometers | 200 m, plus a 150 m exit region | other |

Exit thresholds and hysteresis are the existing ones (driving ends after 60 s below 1 m/s,
walking after 30 s below 0.4 m/s; details in [Live tracking: the sending side](../live-tracking-client.md)).

Still mode in detail:

- **Entering.** iOS delivers fixes only on movement (distance filter), so the 10 minute
  stillness rule needs a clock: the plugin now runs a 5 minute timer that calls the existing
  Dart heartbeat callback (the same `/devices/heartbeat` POST Android sends every 10 minutes).
  The tick re-evaluates the cadence, so still mode starts 10 to 15 minutes after the last move.
- **The wake-up region.** On entering still mode the plugin arms an exit-only `CLCircularRegion`
  (`orbitly.still`) of 150 m (or the fix's accuracy if larger) around the newest fix with an
  accuracy of 100 m or better. On exit the plugin, without waiting for Dart, switches back to the
  slow request and restarts updates so a fresh fix arrives at once. That fix carries
  `native_reset: true`; Dart then forgets the request it last applied and the idle anchor, so
  the phone stays out of still mode for at least another 10 minutes.
- **Coarse fixes.** At three kilometers accuracy iOS uses cell towers only. Such fixes (worse than
  100 m) are not reported while still or as the first fix after a wake-up: a cell fix can be a
  kilometer off and would make the person jump on the family map. One exception: a coarse fix
  whose whole error circle lies outside the 150 m region ends still mode (backup for a region
  exit that never fires).
- **No region monitoring** (unsupported or a monitoring failure): still mode uses hundred-meter
  accuracy (Wi-Fi) instead, so the 200 m filter notices leaving.

## Decisions

- **`pausesLocationUpdatesAutomatically` stays `NO`.** When iOS pauses updates in the
  background, they only resume when the app is opened again (Apple's documentation of the
  property), so a family member who drives off after a pause would vanish. Still mode is the
  controlled replacement: the same saving, with a defined wake-up. With the flag off, the
  activity type does not trigger pauses; it is still set so Core Location can tune its
  filtering (automotive while driving, fitness while walking).
- **No `CMMotionActivityManager`.** It would add a Motion & Fitness permission prompt and a second
  wake source without being needed for the decision: speed from GPS and the region exit cover
  moving and still. `NSMotionUsageDescription` stays in Info.plist because the app links Core
  Motion through `sensors_plus` (driving detection), which can need it.
- **Significant-location-change stays on** as a cheap backup wake-up and the relaunch trigger
  after termination.
- **Deferred updates are not used** (deprecated since iOS 13).
- **No `kCLLocationAccuracyBestForNavigation`.** Apple intends it for navigation apps on external
  power; `best` is enough for 1 Hz driving.
- **`allowsBackgroundLocationUpdates`** is set to `YES` only when the service is registered or
  resumed after a relaunch (the `location` background mode is declared), and back to `NO` when
  the service stops.
- **`showsBackgroundLocationIndicator`** stays on (registration setting, unchanged): people can
  see that location is in use. It is saved so a relaunch restores it.

## Relaunch after termination

If the app is terminated while sharing, the plugin arms a termination region (at least 150 m)
around the last good fix, and significant-change monitoring keeps running. When iOS relaunches the
app for either event, the plugin starts the background isolate, re-applies the slow request,
turns background updates back on, restarts the heartbeat and both location services. The first fix
is held until the isolate reports that it is ready, then delivered with `native_reset: true`.
The older behavior (one fix per region hop after a relaunch) is gone.

## SOS, places and live viewers

- SOS runs in the foreground reporter (its own location stream); the background request
  never delays it. In the background the boosted and SOS tiers are applied at once (the
  existing "urgent" rule of `ProfileApplier`).
- Place arrivals and departures are evaluated on the server (and on the phone for private
  circles) from fixes. In still mode a departure produces a fix on region exit. Apple
  documents region events within 3 to 5 minutes on average, so a departure can show up to a few
  minutes later than with the old always-on request. The architecture budget for iOS is 5 minutes
  from starting to move to the first live fix.

## Battery rationale and sources

The quotes were collected on 2026-11-08 for the optimisation research notes
(`docs/design/RESEARCH_NOTES_PERFORMANCE.md` on the architecture branch); this page did not
re-read them.

- Apple's energy guide: lowest acceptable accuracy, a distance filter, and region (or visit)
  monitoring instead of continuous updates; significant-change monitoring runs "around the
  clock":
  https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html
- `desiredAccuracy` (defaults to best):
  https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy
- `pausesLocationUpdatesAutomatically`: a pause "ends access to location changes until the app
  launches again"; Apple suggests turning it off and dropping to
  `kCLLocationAccuracyThreeKilometers` in the background instead:
  https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically
- Region monitoring (20 regions per app, radii "between 1 and 400 meters work better", events
  "within 3 to 5 minutes on average"):
  https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions
- Significant-location-change (500 m, at most every 5 minutes, relaunches a terminated app):
  https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()
- Background updates and the indicator:
  https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background
- App Review guideline 2.4.2 (apps must not "rapidly drain battery"):
  https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility

## What CI must show

The macOS jobs are the only compile proof. In the run for this change:

1. `test.yml`, job `ios`, step "Build for the iOS Simulator (unsigned)": the step passes and its
   log has no `error:` line mentioning `background_locator_2`. Search the log for
   `BackgroundLocatorPlugin.m`, `MethodCallHelper.m`, `Util.m`, `PreferencesManager.m` and
   `Globals.m`: any `warning:` there (for example "does not conform to protocol",
   "conflicting return type", "undeclared selector", "incompatible pointer") must be read and
   fixed, even if the build passed.
2. Same job, step "Boot a simulator, install, and launch the app": passes (the plugin
   registers on launch without crashing).
3. `ios-unsigned.yml` (device build, `flutter build ios --release --no-codesign`): passes, same
   log search for the arm64 compile.
4. Optional simulator check of the switch: run the app in the simulator with location set to
   "Freeway Drive" (Features > Location), sign in and allow location "Always", background the
   app, and watch Console for `background_locator_2: request` lines (accuracy -1 = best while
   driving). Then set a fixed location and wait 15 minutes: expect `accuracy=3000 ... still=150`
   and `still region armed`.

## Test plan on a real iPhone

Use a TestFlight build, location "Always" with precise location on, Low Power Mode off. Note the
start time and battery level for each run; Console.app (device connected, filter
`background_locator_2`) shows the request lines without coordinates.

1. **Still.** Leave the phone at home, screen off, for 2 hours. Expect: after 10 to 15 minutes
   a `accuracy=3000 ... still=150` line and `still region armed`; no location arrow in the
   status bar between heartbeats; "last seen" on another phone stays fresh (heartbeat every
   5 minutes). Settings > Battery should list Orbitly with a low background share.
2. **Walk.** From still mode, walk away (300 m or more). Expect `wake-up (region exit)` within
   about 5 minutes of leaving, then `accuracy=10 filter=15` once walking speed is seen; the
   family map follows; leaving home triggers the place departure.
3. **Drive.** Drive for 15 minutes. Expect `accuracy=-1 filter=10 activity=2` (automotive) and
   a smooth track; on arrival and 10 to 15 minutes parked, still mode again.
4. **Live viewer.** While still, open the person on another phone. Expect a boosted request
   (`filter=5`) within seconds (live boost push) and fresh positions, then back to still after
   the boost.
5. **Relaunch.** Swipe the app away from the app switcher, then walk or drive 1 km. Expect a
   relaunch by significant change or the termination region (`relaunched by a location event`),
   and positions resuming without opening the app. Whether iOS relaunches a force-quit app is
   not settled ([iOS release notes](../design/IOS_RELEASE.md) expect no relaunch); record what
   actually happens.
6. **Reboot.** Restart the phone, do not open the app, walk 1 km. Record whether positions
   resume.
7. **Day test.** One normal day; screenshot Settings > Battery (24 hours, by app) for the
   release notes. Budget: 3% per stationary day and 8% per mixed day attributable to Orbitly.
