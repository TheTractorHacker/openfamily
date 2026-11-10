# Apple Watch app (companion model)

Status: **written without a Mac. No Swift, Xcode project change, plist or workflow in this
feature has been compiled, run in a simulator or tried on a watch.** The shared Dart side is
tested on Linux (`watch_bridge_test.dart`). Read [What the first CI run must prove](#what-the-first-ci-run-must-prove)
before trusting any line here.

This page is the Apple half of [WATCH_APPS.md](WATCH_APPS.md), which owns the decision, the
security model, the snapshot JSON and the command table for **both** watches. This page only
covers what is specific to Apple.

## Pieces

| Piece | File | Role |
|---|---|---|
| Watch app (SwiftUI, watchOS 9+) | `app/ios/OrbitlyWatch/*.swift` | UI, last snapshot in UserDefaults |
| iPhone native bridge | `app/ios/Runner/WatchBridge.swift` | WCSession delegate, channel `app.openfamily/watch` |
| Dart bridge (shared with Wear OS) | `app/lib/services/watch/watch_bridge.dart` | throttle, commands, sign-out debt |
| Snapshot model (shared) | `app/lib/services/watch/watch_snapshot.dart` | JSON contract, single source of truth |
| Settings screen (shared) | `app/lib/screens/watch_settings_screen.dart` | one "Watch" row, wording follows the platform |
| Xcode target | `app/ios/Runner.xcodeproj` (ids `AB1C0DE0...`) | target `OrbitlyWatch`, embedded in the iPhone app |
| Kill switch | `scripts/ios-watch-target.py` | removes the target from the project |

## Transport (WatchConnectivity)

| Direction | API | Used for |
|---|---|---|
| phone to watch | `updateApplicationContext(["snapshot": json, "session": id])` | the latest snapshot; newer replaces older, no queue |
| phone to watch | `updateApplicationContext(["cleared": true, "session": id?])` | sign-out or switch off: the watch deletes its copy |
| watch to phone | `sendMessage(["json": command], replyHandler)` | every command; needs the phone reachable. The reply only means "taken"; the result is `lastCommand` in the next snapshot |

No polling on either side. The watch waits at most 20 seconds for the phone's answer and then
says "No confirmation from the iPhone". Nothing is queued, so a stale SOS can never fire later.

Cadence (same Dart bridge as Wear OS, [WATCH_APPS.md](WATCH_APPS.md), Cadence): the watch app
sends `visible` when its scene becomes active and once a minute while it stays active (the only
timer, and only while on screen), `visible` with `ambient` when the scene goes inactive (wrist
down, always-on), and `hidden` in the background, all fire and forget through `sendMessage`
when the iPhone is reachable. The iPhone then sends every few seconds while the app is on
screen and only meaningful changes, at most every 2 minutes, otherwise.
`updateApplicationContext` has no urgency switch, so the `urgent` flag the bridge passes is
ignored on the iPhone. Member lines with a relative time come as `line` plus `lineAt`, and the
watch adds the age itself ("Left Work 25 min ago"). The Swift changes for this were not
compiled here (no Xcode on the build host); the first macOS CI run proves them.

## Sign-out and switch-off are a debt

The shared Dart bridge keeps its pending flag. The native side adds two persisted facts of its own:
`blocked` (no data may be sent: set by `clear`, lifted by `allowPublish`) and `clearUndelivered`
(the wipe has not yet been accepted by WatchConnectivity). A new sign-in does **not** reset
`clearUndelivered`: `allowPublish` creates a new session id and sends the wipe first (and with the new
id). Every context carries the session id; the watch drops what it stored for any other session, a
`cleared` context, or a snapshot with `signedIn: false`. `clear` answers `true` to Dart only once the wipe was handed over.

Known gap on the Wear OS side (not changed here): its `allowPublish` clears the native pending flag
without first making sure an undelivered delete reached the watch. A new snapshot replaces the item, so
the old data is overwritten once the watch is reachable, but until then the watch can still show the old
user's data. The same session-id idea would close it.

## Watch UI

People list (initials avatar, name, "At Home" / "Driving 42 mph" / "2 min ago", battery), person
detail (place, address, age, battery, Handoff note), **Distance and direction** (compass arrow,
see below), SOS, I'm OK, Pause or Resume sharing, Quick replies with an unread badge, Alerts.
Dynamic Type is respected (system text styles, line limits of 1 to 2 lines, scrolling views).
Offline: the last snapshot is shown with "iPhone not reachable" and its age.

Direction view (v0.26.30, Precision Finding style): the arrow turns with your wrist. The watch reads
its own compass (`CLLocationManager` heading, `headingFilter` 1 degree) only while the screen is
open and awake: it starts in `onAppear`, and stops in `onDisappear` and whenever
`isLuminanceReduced` is true (wrist down, always-on). Arrow angle = bearing to the person (from the
snapshot) minus the watch heading. Only `trueHeading` is used (the phone bearing is a true bearing;
`magneticHeading` would be off by the declination); one `requestLocation()` is asked so the system can
give it, and until then the arrow is north-up. The last valid heading is kept across stop/start, so
waking the screen never snaps the arrow to north-up. This needs
`NSLocationWhenInUseUsageDescription` in `OrbitlyWatch/Info.plist`; the watch position itself is
neither used nor stored. The angle is drawn by a `TimelineView(.animation(minimumInterval: 1/30))`
that is paused while dimmed, and also once both smoothers have settled while there is no compass
(`isSettled`; it resumes on a new bearing). `AngleSmoother` (Format.swift) keeps an unwrapped angle (359 to 1
degrees turns 2 degrees, not 358), eases it with a frame-rate independent exponential (tau 0.14 s)
and ignores changes under 1 degree. The ring and its N counter-rotate so north stays where it is.
Without a compass reading (not available, not yet ready, refused) the arrow is north-up as before.
Under 15 m (left again above 30 m) the bearing is noise, so the screen says "<name> is close" and
dims the arrow. "Updated N s ago" shows how old the other person's fix is.

Opening the screen sends `visible` with arg `finding` (still repeated once a minute); the iPhone then
sends at most every 2 s instead of 5 s (`WatchBridge.findingInterval`), `finding` ends with any other
presence command or with the 150 s expiry. The origin of the bearing is still the signed-in person's
position from the family roster (the iPhone), and the other person's position is only as fresh as
their phone's reports and `updateApplicationContext` delivery; positions are rounded to 5 decimals
(about 1 m). None of this was measured on a watch.

## Complications: not shipped

A WidgetKit complication needs a widget extension target, an App Group (or shared Keychain) to
read the snapshot, and a second set of pbxproj objects. With nothing able to compile here that
doubles the chance of breaking the iPhone build, so **v1 ships without complications**.
Future: a widget extension inside the watch app reading the snapshot from an App Group
`group.app.openfamily` (accessoryCircular: unread or battery of the first person;
accessoryRectangular: two people; accessoryInline: "Anna at Home").

## Standalone LTE: future work only

Evaluated, not built. It would need: a watch-side login (QR or code from the phone), tokens in
the watch Keychain, the E2EE circle keys copied to the watch (or Private circles hidden there),
a polling or push strategy for a device that sleeps (APNs to the watch), and its own SOS
location (the watch GPS). Verdict: worth doing after the companion version has proven itself,
and only with Private circles excluded on the watch unless the owner decides otherwise.

## Xcode project

Hand-edited `project.pbxproj` (no XcodeGen: nothing could install and run it here, and a second
tool in the release path is a second thing to break). All Watch objects use ids that start with
`AB1C0DE0`, which is what makes the kill switch exact.

- Target `OrbitlyWatch`, product type application, `SDKROOT=watchos`,
  `SUPPORTED_PLATFORMS="watchos watchsimulator"`, `WATCHOS_DEPLOYMENT_TARGET=9.0`,
  `TARGETED_DEVICE_FAMILY=4`, bundle id `app.openfamily.watchkitapp`, `SWIFT_VERSION=5.0`,
  Info.plist `WKApplication=true`, `WKCompanionAppBundleIdentifier=app.openfamily`.
- `Runner` gets a target dependency on it and an **Embed Watch Content** copy phase
  (destination Products Directory, path `$(CONTENTS_FOLDER_PATH)/Watch`), placed before
  "Thin Binary" to avoid a build cycle.
- The watch target has its own `Watch.xcconfig` that only includes `Generated.xcconfig`, to
  get `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER` so the watch version equals the iPhone
  version (the App Store checks this). It deliberately does **not** use Flutter's
  `Release.xcconfig`, because the signed-release workflow appends the iPhone bundle id and
  provisioning profile to that file.
- Signing: `CODE_SIGN_STYLE=Automatic` with no team. Unsigned CI builds pass
  `CODE_SIGNING_ALLOWED=NO` so no profile is needed.
- App icon: the 1024 px Orbitly icon as the single watchOS icon (copied from the iPhone
  asset, which `assets/brand/build-rasters.mjs` regenerates; copy it again when the brand
  changes). Accent color is the brand lime.

### Kill switch

If the watch target breaks the iPhone build:

```
python3 scripts/ios-watch-target.py disable
git add app/ios && git commit -m "Remove the Apple Watch target from the Xcode project"
```

It strips every `AB1C0DE0` object from the pbxproj and deletes the `OrbitlyWatch` scheme. The
result was verified byte for byte against the project without the watch (done in Docker on
Linux). The iPhone side (`WatchBridge.swift`, the Dart bridge) stays and finds no watch.
Check the project with `python3 scripts/ios-watch-target.py check`; re-enable with `git revert`.

## Builds and signing

- **Simulator job** (`test.yml` job `ios`) is unchanged and still blocking. It now builds the
  watch app as a dependency of Runner, so it is also the first thing to fail if the project edit
  is wrong.
- **Watch job** (`test.yml` job `watchos`) builds `-scheme OrbitlyWatch` for
  `generic/platform=watchOS Simulator`, builds the iPhone app and checks that
  `Runner.app/Watch/OrbitlyWatch.app` exists. **`continue-on-error: true` for now.**
- **Unsigned IPA** (`ios-unsigned.yml`): `cp -R` of `Runner.app` already carries `Watch/`; a new
  check fails the job if the project has the watch target but the app is missing, and the IPA
  listing is checked for it. Sideload tools must **sign the watch bundle too** (see the user
  page).
- **Signed TestFlight** (`ios-release.yml`): the watch app needs its own App Store profile and
  an entry in `ExportOptions.plist`. Until the owner sets repository variable
  `IOS_WATCH_ENABLED=true` and adds those, the workflow runs the kill switch first, so the
  signed path behaves exactly as before. Needed for enabling: App ID
  `app.openfamily.watchkitapp`, an App Store profile, a second `provisioningProfiles` entry.

## What the first CI run must prove

Nothing below has ever happened.

1. `python3 scripts/ios-watch-target.py check` passes on the runner (it does on Linux).
2. `xcodebuild -showsdks` lists a watchOS Simulator SDK on `macos-15`; if not, nothing here can build.
3. The SwiftUI and WatchConnectivity sources compile with the runner's Swift (the most likely
   failures are small type or API mistakes in `OrbitlyWatch/*.swift`).
4. The asset catalog compiles (single 1024 px watchOS icon, accent color).
5. Xcode accepts the hand-written target: no "cycle in dependencies", no missing file, no
   "Info.plist" or "product" error.
6. **The existing iPhone jobs still pass**: `flutter build ios --simulator` and the
   `RunnerTests` job, with the watch app built as a dependency for the matching simulator SDK.
   Flutter passes `-sdk iphonesimulator` style arguments; whether Xcode then builds the watch
   dependency with the watch simulator SDK is **unproven**.
7. `flutter build ios --release --no-codesign` (unsigned IPA job) embeds `Watch/OrbitlyWatch.app`
   and the IPA zip contains it.
8. `Runner/WatchBridge.swift` compiles and the iPhone app still launches in the simulator
   (`simctl launch`).
9. Not provable in CI at all: pairing, install through the iPhone Watch app, the snapshot arriving,
   SOS and every command end to end, Handoff, layout on the small and large watch sizes,
   Dynamic Type. That needs a real iPhone and watch.

## Risk to the iPhone release

The pbxproj edit touches the iPhone target (a dependency and an embed phase). If it is wrong,
**the whole iOS build fails**, including the unsigned IPA. Mitigations: the new job is separate,
the kill switch is one command and tested for exactness, the signed workflow disables the watch
by default, and the Xcode edit follows the layout Xcode 14+ itself writes for a single-target
watch app. Remaining risk: a build setting or phase ordering that only a real Xcode rejects.
If the first CI run is red in the `ios` job after this merges, run the kill switch before
anything else.
