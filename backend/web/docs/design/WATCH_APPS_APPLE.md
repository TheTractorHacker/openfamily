# Apple Watch app (companion model)

Status: **written without a Mac. No Swift, Xcode project change, plist or workflow in this
feature has been compiled, run in a simulator or tried on a watch.** The Dart side is tested
on Linux. Read [What the first CI run must prove](#what-the-first-ci-run-must-prove) before
trusting any line here. This page is the Apple half of the watch design; the Wear OS half is
`WATCH_APPS.md` (the merge of the two branches should fold this into that page as an
"Apple Watch" section).

## Decision: companion model

The iPhone app stays the **only holder of the sign-in session, tokens and end-to-end keys**.
The watch is a screen and a remote control:

- The phone builds a small, already-decrypted **snapshot** and pushes it.
- The watch sends back **commands**. The phone runs them with its own credentials and keys.
- Nothing on the watch can call the server and nothing secret is stored there.

Why not standalone: a standalone watch would need its own tokens and its own copy of the
Private-circle keys. That doubles the key-handling surface for a feature people use at a glance.

## Pieces

| Piece | File | Role |
|---|---|---|
| Watch app (SwiftUI, watchOS 9+) | `app/ios/OrbitlyWatch/*.swift` | UI, last snapshot in UserDefaults |
| Phone native bridge | `app/ios/Runner/WatchBridge.swift` | WCSession delegate, channel `app.openfamily/watch` |
| Phone Dart bridge | `app/lib/services/watch/watch_bridge_ios.dart` | throttled pushes, runs commands |
| Snapshot model | `app/lib/services/watch/watch_snapshot.dart` | JSON shape, distance and direction |
| Phone actions | `app/lib/services/watch/watch_actions.dart` | SOS, check-in, pause, reply on the real services |
| Settings screen | `app/lib/screens/watch_apple_screen.dart` | status and the on/off switch |
| Xcode target | `app/ios/Runner.xcodeproj` (ids `AB1C0DE0...`) | target `OrbitlyWatch`, embedded in the iPhone app |
| Kill switch | `scripts/ios-watch-target.py` | removes the target from the project |

## Transport (WatchConnectivity)

| Direction | API | Used for |
|---|---|---|
| phone to watch | `updateApplicationContext(["snapshot": json])` | the latest snapshot; newer replaces older, no queue |
| phone to watch | `transferUserInfo(["alert": json])` | one alert that must not be lost (the Dart method exists in the channel; nothing in the app calls it yet, alerts currently ride in the snapshot) |
| watch to phone | `sendMessage(["cmd": ...], replyHandler)` | every command; needs the phone to be reachable; the answer is `{ok, message}` |
| phone to watch | `updateApplicationContext(["cleared": true])` | sign-out or switch off: the watch deletes its copy |

There is no polling and no timer on either side. The phone pushes when the family roster
changes, at most once per 15 seconds, and only when a watch with the app is paired. The extras
(circle names, unread counts, recent alerts, pause state) are fetched at most once a minute.

## Snapshot (version 1)

Defined in `watch_snapshot.dart`; the Wear OS app uses the same JSON.

```
{ "v":1, "ts":<ms>, "units":"imperial|metric",
  "me":{"id","name","sharing":bool,"pausedUntil":<ms>|null},
  "circles":[{"id","name","unread":int,"active":bool,"members":[
     {"id","name","initials","color":<ARGB>,"me":bool,
      "state":"still|driving|bike|boat|plane|home|work|gym|star",
      "speedMps":num|null,"place":str|null,"atPlace":bool,"address":str|null,
      "fixTs":<ms>|null,"battery":0-100|null,"stopped":bool,"hasPosition":bool,
      "distanceM":num|null,"bearingDeg":num|null}]}],
  "alerts":[{"id","kind","title","body","ts","active"}],
  "quickReplies":[str] }
```

- Only the **active circle** carries members (the app holds one roster at a time). The other
  circles appear with name and unread count.
- At most 24 members and 8 alerts. Decoding on the watch is forgiving: a missing field takes a
  default, so a newer or older phone app never crashes the watch app.
- **No coordinates** are sent. The phone computes distance and compass bearing from your own
  position to theirs. The watch cannot place anyone on a map; "Open on iPhone" is Handoff.

## Commands

All are sent by `sendMessage`; the phone answers `{ok, message}` and the watch shows the message.

| `cmd` | Phone does | Notes |
|---|---|---|
| `sos` | `POST /alerts/sos` with the phone's position, stores the alert id so the phone's SOS screen shows it, starts the position burst | press and hold, then a 5 second countdown with Cancel, on the watch |
| `sosResolve` | `POST /alerts/{id}/resolve` | "I'm safe" |
| `checkin` | `POST /checkins` to the other members of the active circle with note "I'm OK" | |
| `pause` / `resume` | `PUT` / `DELETE /sharing/pause` (15 minutes to 24 hours) | |
| `reply` | `ChatService.send` | **only the fixed phrases** in `kWatchQuickReplies`; anything else is refused. The phone seals it itself if the circle is Private |
| `markRead` | `ChatService.markRead` | |
| `refresh` | pushes a fresh snapshot | |

Honesty rules: **SOS is never queued.** If the phone is not reachable the watch says
"SOS NOT sent" and "call emergency services"; a stale SOS firing later would be dangerous.
The same text says that emergency services are not contacted by Orbitly.

## Privacy

- Tokens, refresh tokens, circle keys and the server URL never leave the phone.
- Private circles: the phone decrypts as usual and the **readable** names, places and
  addresses are sent to the watch over WatchConnectivity, which is the encrypted
  phone-to-watch link of the same Apple ID. They do not touch the server, a push provider or the
  internet on the way. The watch stores the last snapshot in its own UserDefaults (watch
  storage); it is wiped on sign-out, on switching the setting off, and when the app is deleted.
  A person who must not have their Private location on a wrist cannot opt out per person yet;
  the single switch in Settings, Watch turns the whole thing off.
- The watch app has its own privacy manifest (`OrbitlyWatch/PrivacyInfo.xcprivacy`): no
  collection, UserDefaults reason CA92.1.
- Handoff carries only a member id (activity `app.openfamily.watch.person`).

## Watch UI

People list (initials avatar, name, "At Home" / "Driving 42 mph" / "2 min ago", battery), person
detail (place, address, age, battery, Handoff note), **Distance and direction** (north-up arrow,
see below), SOS, I'm OK, Pause or Resume sharing, Quick replies with an unread badge, Alerts.
Dynamic Type is respected (system text styles, line limits of 1 to 2 lines, scrolling views).
Offline: the last snapshot is shown with "iPhone not reachable" and its age.

Direction view limitation: the arrow is **north-up**, computed by the phone. It does not turn
with your wrist (no heading sensor is read, to keep the battery). A live heading is future work.

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
