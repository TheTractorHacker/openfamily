# iOS app: readiness, signing, TestFlight and release decision

Issue: #52. Status: **everything below was written without a Mac and without an Apple
account. No Swift, Objective-C, Xcode project, plist or workflow change on this page has ever
been compiled, run, signed or uploaded.** Dart code and the Go backend are tested in CI on
Linux; the native iOS side is "carefully written, unverified". Signed distribution is
**BLOCKED** until the owner has an Apple Developer Program account (99 USD/year) and a Mac or
the GitHub macOS runner has run the workflow once.

Read [Verification status](#verification-status) before trusting any line here.

## Decision

Use **TestFlight** for family members' iPhones: invite by email or link, automatic updates, no
UDID handling, the same signed archive can later go to the App Store. Alternatives (ad hoc,
public App Store, free-account sideloading) are in the table at the end.

## What exists in the repo

| Piece | Where | State |
|---|---|---|
| Flutter iOS shell, bundle id `app.openfamily`, deployment target iOS 15.0 | `app/ios/` | simulator build runs in CI (`test.yml` job `ios`) |
| Secure key storage (Secure Enclave wrapping key, Keychain fallback) | `app/ios/Runner/SecureKeyChannel.swift` | written, unverified |
| Screen obscuring for the recovery phrase | `app/ios/Runner/ScreenProtector.swift` | written, unverified |
| Invite links (universal link + `openfamily://`), tel/sms/otpauth launcher | `app/ios/Runner/LinkBridge.swift`, `Info.plist` | written, unverified |
| APNs registration, silent command handling | `app/ios/Runner/AppDelegate.swift` | pre-existing, unverified on a device |
| Privacy manifest | `app/ios/Runner/PrivacyInfo.xcprivacy` | written, unverified |
| Universal Links file | backend `GET /.well-known/apple-app-site-association` (env `IOS_TEAM_ID`, `IOS_BUNDLE_ID`) | Go tests pass |
| Release workflow | `.github/workflows/ios-release.yml` (gated by `IOS_RELEASE_ENABLED`) | never run |
| Export options template | `app/ios/ExportOptions.plist` | template, never used |
| Apple Watch app (SwiftUI, embedded in the iPhone app; companion model) | `app/ios/OrbitlyWatch/`, `Runner/WatchBridge.swift`, [WATCH_APPS_APPLE.md](WATCH_APPS_APPLE.md) | written, never compiled; own non-blocking CI job `watchos`; TestFlight leaves it out until `IOS_WATCH_ENABLED=true`; kill switch `scripts/ios-watch-target.py disable` |
| Xcode unit tests (key logic, link filter) | `app/ios/RunnerTests/RunnerTests.swift` | never run; run by `test.yml` job `ios` on the macOS runner |

## Feature table: what works on iPhone

Status words: **works** = shared Dart code or a plugin with iOS support, expected to work but
untested on a device; **ported** = native iOS code was written here, unverified;
**needs port** = native iOS work still to do; **not possible** = iOS does not offer the API;
**n/a** = Android concept with no iOS equivalent.

| Feature | iOS status | Notes |
|---|---|---|
| Sign in, circles, places, alerts, chat, trips list, weekly summary | works | pure Dart over HTTPS |
| Live map | works | `flutter_map`, vector tiles |
| Foreground location | works | `geolocator` with `AppleSettings` |
| Background location | works, unverified | `background_locator_2` (vendored, Objective-C): `startUpdatingLocation` plus significant-change monitoring, `UIBackgroundModes: location`, "Always" permission, blue status-bar indicator on. Needs a field test (see below) |
| Relaunch after the system killed the app | works, unverified | plugin relaunches via `UIApplicationLaunchOptionsLocationKey`; `AppDelegate` registers plugins on the headless engine. Not after a force-quit by the user (iOS rule) |
| Heartbeat every ~10 min while idle | needs port | the plugin's heartbeat is an Android alarm; on iOS nothing runs when the phone is stationary and the app suspended. "Last seen" can go stale |
| Push alerts (SOS, check-in, places) | works, unverified | APNs, `app.openfamily/apns` channel; needs `APNS_*` on the server and the Push Notifications capability |
| Silent commands (location refresh) and E2EE wake-ups | best effort | `content-available` pushes; iOS throttles them, drops them in Low Power Mode and after a force-quit |
| End-to-end encrypted circles | ported | same Dart crypto; wrapping key in the Secure Enclave. See `E2EE.md`, "iOS differences" |
| Recovery phrase screen protection | ported, weaker than Android | cannot block screenshots; hides on screen recording/mirroring and in the app switcher |
| Biometric app unlock | works | `local_auth`, `NSFaceIDUsageDescription` present |
| Invite link `openfamily://join?...` | ported | URL scheme in `Info.plist`, `LinkBridge.swift` |
| Invite link `https://<server>/join/<code>` opens the app | needs owner setup | Universal Links need the Associated Domains entitlement per server host, built into the app. Only the maintainer's own server(s) can use it; other self-hosted servers fall back to the landing page button (`openfamily://`) or paste/QR |
| Camera and photo picker (chat, avatar) | works | `image_picker`; `NSCameraUsageDescription` was missing and was added |
| Contact picker (emergency contacts) | works | system picker, no permission |
| Share sheet | works | `share_plus` |
| SOS "Call emergency number" | ported | `tel:` through `app.openfamily/launcher`; iOS asks the user to confirm the call |
| Open authenticator app for 2FA | ported | `otpauth:` via the same channel |
| Person "call/text/navigate" | ported | `tel:`, `sms:`; `geo:` is translated to Apple Maps |
| Driving detection: hard braking, rapid acceleration | needs port | Android `driving_native` plugin feeds GPS speed and screen state; the Dart side is guarded and the screen says "Not available on iPhone yet". A Swift port (CoreMotion + `CLLocation.speed`) is possible but must run in the background isolate |
| Driving detection: phone use while driving | not possible (mostly) | iOS exposes no screen/unlock/handling signals to third-party apps beyond CallKit call state; hidden on iPhone |
| Crash detection | needs port, limited | no continuous background accelerometer on iOS unless a location session keeps the app alive; Apple's own Crash Detection (iPhone 14+) is not available to third parties. Hidden on iPhone |
| Trips and driving report (GPS based, server side) | works | computed on the server from locations |
| Car UI mode / Android Auto | not possible | CarPlay needs an Apple-granted entitlement and a different app type; nothing exists on Android here either except the sensors |
| Home-screen widget | needs port | Android `AppWidget`; iOS needs a WidgetKit extension plus an App Group. Setting is hidden on iPhone |
| Battery-optimization exemption prompt | n/a | hidden on iPhone |
| UnifiedPush / ntfy | n/a | APNs is the iOS channel |
| Direct push stream (SSE) | works, limited | only while the process is alive (location background mode) |

What the app does when a feature is missing: `app/lib/services/platform_features.dart` is the
single switch (`drivingSensors`, `homeWidget`, `notOnIphone`). Settings > Driving detection
shows "Not available on iPhone yet"; the background hook, crash watcher and opt-in sync do
nothing on iOS, so the server is never told the user opted in to sensors that cannot run; the
Core Motion permission step is not offered.

## Background execution on iOS: how the Dart code behaves

Verified by reading the code, not by running it.

* **Background isolate.** `background_locator_2` starts a headless `FlutterEngine` and runs the
  Dart callbacks `onLocationUpdate` / `onHeartbeatTick` in it. `AppDelegate.swift` registers
  `GeneratedPluginRegistrant` on that engine (so `shared_preferences`, `flutter_secure_storage`,
  `battery_plus` work) and now also registers the `app.openfamily/keystore` channel on it, so
  the isolate can use the Secure Enclave wrapping key to seal location for Private circles. If
  the channel were missing, `SecureVault` would see "unavailable" and the sealing code would
  park fixes instead of sending plaintext (existing safety behaviour).
* **Credentials in the background** are in the Keychain with `first_unlock_this_device`
  (`BackgroundCredentialStore`), readable while the phone is locked after the first unlock.
  Before the first unlock after a reboot nothing can be read; location callbacks then skip
  silently.
* **Location triggers.** Continuous updates while the process lives; significant-location-change
  (about 500 m, cell-tower based) relaunches a killed app; a 50 m exit-region is armed when the
  app terminates. Results are bursty, not a steady cadence. The `TrackingCadence` profiles
  (1 s to 60 s intervals) are Android concepts: on iOS only `distanceFilter` applies.
* **No `workmanager`, no `BGTaskScheduler`.** Nothing in the app registers a BGTask, and
  `UIBackgroundModes` deliberately lists only `location` and `remote-notification`
  (no `fetch`, no `processing`, which would invite App Review questions without a feature
  behind them). Periodic work is not possible; wake-ups come from location events and pushes.
* **Silent push.** The backend sends `content-available` pushes with `apns-push-type:
  background` for commands and the content-free E2EE wake-up. `AppDelegate.application(_:
  didReceiveRemoteNotification:fetchCompletionHandler:)` forwards the `of` payload to Dart. Apple
  does not guarantee delivery: heavy throttling (a few per hour), none after a force-quit, none
  in Low Power Mode. E2EE correctness never depends on them: the app pulls on open, and
  live location keeps flowing over the location background mode.
* **Unverified:** all of it. The first device test must cover: lock the phone for 30 minutes
  while walking; kill the app from the app switcher (expect no relaunch: documented iOS rule);
  reboot and walk 600 m (expect a relaunch through significant changes); send a location-refresh
  command and an E2EE wake-up and time them.

## Info.plist, entitlements, Podfile: audit result

Read in full. Changes made are marked **fixed**; the rest were checked and left.

* `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`,
  `NSMotionUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSFaceIDUsageDescription`:
  present. `NSMotionUsageDescription` is kept although no Core Motion permission is requested
  today (kept for the future port; App Review does not reject an unused string).
* **fixed:** `NSCameraUsageDescription` was missing. Chat uses `ImageSource.camera`; without
  the string iOS terminates the app the moment the camera sheet opens.
* **fixed:** `CFBundleURLTypes` for `openfamily://` was missing, so the landing-page button could
  not open the app. `FlutterDeepLinkingEnabled=false` stops Flutter from also pushing the URL
  path to the Navigator (the app routes invite links itself).
* `UIBackgroundModes`: `location`, `remote-notification` (kept; see above).
* `Runner.entitlements`: `aps-environment` from the build setting `APS_ENVIRONMENT`
  (development for Debug/Profile, production for Release). Associated Domains are **not** in
  the default entitlements on purpose: the host differs per self-hosted server, and an
  entitlement the App ID lacks breaks signing. The workflow adds `applinks:<domain>` when the
  repository variable `IOS_ASSOCIATED_DOMAIN` is set.
* **fixed:** `Flutter/Debug.xcconfig` and `Release.xcconfig` did not include the CocoaPods
  configuration (`Pods-Runner.*.xcconfig`), so the pods (geolocator, background_locator_2, ...)
  would not link on a real build. Optional includes (`#include?`) were added.
* **fixed:** `permission_handler` compiles every permission out on iOS unless a preprocessor
  macro is set, and then every request silently returns "denied". `Podfile` now sets
  `PERMISSION_LOCATION=1` and `PERMISSION_NOTIFICATIONS=1` (and nothing else).
* **fixed:** Privacy manifest `PrivacyInfo.xcprivacy` added and wired into the Runner resources:
  no tracking, the collected data types from `PRIVACY.md` (precise/coarse location, email, name,
  phone, user id, device id, photos, user content, contacts-category for emergency contacts), and
  the required-reason API categories the app code and the Flutter engine use (UserDefaults
  `CA92.1`, file timestamp `C617.1`, boot time `35F9.1`, disk space `E174.1`). Plugins ship
  their own manifests, which Xcode merges. Review the generated privacy report in Xcode.
* Podfile: platform 15.0 matches the project; a post-install hook lifts older pod targets.
  `background_locator_2` declares iOS 8.0 and is lifted by that hook. Plugin set vs iOS: all
  listed plugins have iOS implementations except `android_intent_plus` (guarded),
  `unifiedpush` (guarded), `google_api_availability` (guarded) and `driving_native` (Android
  only plugin, skipped by Flutter on iOS).
* Not decided for the owner: `ITSAppUsesNonExemptEncryption`. The app uses encryption beyond
  HTTPS (end-to-end encrypted circles), which may need an export-compliance declaration or an
  annual report. It is deliberately **not** set in `Info.plist`; App Store Connect will ask on
  each upload until you answer it. Take legal advice if unsure.
* Open risk: `Info.plist` has no `UIApplicationSceneManifest`, so the app uses the classic
  `AppDelegate` lifecycle although `SceneDelegate.swift` exists. If a future Flutter migration
  adds the scene manifest, move the two link callbacks (`open url`, `continue userActivity`) to
  the scene delegate.
* Open risk: the Xcode project references both CocoaPods and the Flutter Swift Package
  (`FlutterGeneratedPluginSwiftPackage`). `AppDelegate` imports `background_locator_2` as a
  module, which works only through CocoaPods; the vendored plugin is an Objective-C pod, so this
  is expected to work, but nobody has built it.

## Owner checklist (exactly what to click and paste)

Time: about 2 hours of your time plus Apple's approval delays (enrolment can take 1 to 2 days).
You need: an Apple ID with two-factor authentication, a payment card, admin access to the
GitHub repository `TheTractorHacker/orbitly`, and a Mac for the first certificate (the
fallback without a Mac is noted in step 4).

1. **Enrol.** Go to https://developer.apple.com/programs/enroll/ and sign in with your Apple ID.
   Enrol as an Individual (fastest) or Organization (needs a D-U-N-S number). Pay 99 USD.
   When it shows "Active", open https://developer.apple.com/account and note your **Team ID**
   (Membership details, 10 characters like `AB12CD34EF`).
2. **Register the App ID.** Certificates, Identifiers & Profiles > Identifiers > the blue `+` >
   App IDs > App > Continue. Description `Orbitly`, Bundle ID **Explicit** `app.openfamily`
   (if that is taken, choose your own reverse-DNS id and set the repository variable
   `IOS_BUNDLE_ID`; also change `PRODUCT_BUNDLE_IDENTIFIER` in `app/ios/Runner.xcodeproj` and
   `APNS_TOPIC` on the server). Tick capabilities: **Push Notifications** and, if you want
   `https://<your server>/join/...` links to open the app, **Associated Domains**. Background
   Modes need no tick here (they live in Info.plist). Continue > Register.
3. **Create the App Store Connect app.** https://appstoreconnect.apple.com > Apps > `+` > New
   App. Platform iOS, Name `Orbitly` (unique across the store: pick another if taken),
   Primary language, Bundle ID `app.openfamily`, SKU `openfamily`, User Access Full Access.
4. **Distribution certificate.** On a Mac: Keychain Access > Certificate Assistant > Request a
   Certificate From a Certificate Authority > your email, Common Name `Orbitly`, Saved to
   disk. On developer.apple.com: Certificates > `+` > **Apple Distribution** > upload the
   `.certSigningRequest` > Download the `.cer`, double-click it to install. In Keychain Access >
   My Certificates, right-click "Apple Distribution: ..." > Export > `.p12`, choose a password
   (this is `IOS_P12_PASSWORD`). Then in Terminal: `base64 -i cert.p12 | pbcopy` (that is
   `IOS_P12_BASE64`). *No Mac?* Create the key and request with OpenSSL (`openssl genrsa -out
   key.pem 2048`, `openssl req -new -key key.pem -out ios.csr -subj "/CN=Orbitly"`), upload
   `ios.csr`, convert the downloaded `.cer` with `openssl x509 -inform der -in ios.cer -out
   ios.pem` and bundle `openssl pkcs12 -export -inkey key.pem -in ios.pem -out cert.p12`.
5. **Provisioning profile.** Profiles > `+` > **App Store Connect** (under Distribution) >
   App ID `app.openfamily` > pick the certificate from step 4 > name it `Orbitly AppStore` >
   Generate > Download. `base64 -i OpenFamily_AppStore.mobileprovision | pbcopy` is
   `IOS_PROVISIONING_PROFILE_BASE64`. Regenerate the profile whenever you change the App ID's
   capabilities (the workflow checks that it contains production push).
6. **App Store Connect API key.** App Store Connect > Users and Access > Integrations > App
   Store Connect API > Team Keys > `+`, name `ci`, access **App Manager**, Generate. Copy the
   **Issuer ID** (top of the page) = `ASC_ISSUER_ID`, the **Key ID** = `ASC_KEY_ID`, and download
   the `.p8` **once** (Apple will not show it again); its full text is `ASC_PRIVATE_KEY`.
7. **APNs key for the server** (separate from step 6). Keys > `+` > tick **Apple Push
   Notifications service (APNs)** > Continue > Register > download `AuthKey_XXXX.p8`. On the
   server put it at the path used by `APNS_KEY_FILE`, and set `APNS_KEY_ID`, `APNS_TEAM_ID`
   (your Team ID), `APNS_TOPIC=app.openfamily`, `APNS_PRODUCTION=true` (TestFlight builds use the
   production APNs environment). The same Team ID also feeds Universal Links: set `IOS_TEAM_ID`
   if you did not set `APNS_TEAM_ID`. Restart the API and check
   `curl https://<server>/.well-known/apple-app-site-association` returns JSON.
8. **GitHub secrets and variables.** Repository > Settings > Secrets and variables > Actions.
   *Secrets* (New repository secret): `IOS_P12_BASE64`, `IOS_P12_PASSWORD`,
   `IOS_PROVISIONING_PROFILE_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` (paste the
   whole `.p8` including the BEGIN/END lines). *Variables* tab: `IOS_TEAM_ID` (your Team ID),
   optional `IOS_BUNDLE_ID` and `IOS_ASSOCIATED_DOMAIN` (your server host, no `https://`), and
   finally `IOS_RELEASE_ENABLED` = `true`.
9. **Run it.** Actions > "iOS release (TestFlight)" > Run workflow > version `0.19.0` (or
   whatever the Android tag is; build number may stay empty). Read the log top to bottom. First
   runs usually fail on signing; the "Import signing certificate and provisioning profile" step
   prints the profile's team, app id and push environment so the fix is visible. The upload step
   validates before it uploads.
10. **Export compliance.** App Store Connect > the app > TestFlight > the build > answer the
    encryption question (see the audit note above).
11. **First TestFlight invite.** App Store Connect > TestFlight > Internal Testing > `+` >
    create a group `Family`, add testers who are *App Store Connect users* (Users and Access >
    `+`, role "Customer Support" or "Marketing" is enough), tick the build. They get an email;
    they install **TestFlight** from the App Store, accept, install Orbitly. For relatives
    without an Apple Developer role use External Testing: add the group, submit the first build
    for Beta App Review (1 to 2 days; paste the background-location justification below), then
    share the public link.
12. **Server side.** In the app set the server URL (HTTPS). Create the first circle and test an
    invite link from the iPhone.

Background-location justification (App Review and the permission dialog):

> Orbitly lets members of a private family circle see each other's location on a map. The
> app only works if location is shared while the phone is in the pocket, so it requests "Always"
> access. The user can turn sharing off in the app at any time and is shown the background
> location indicator. Data goes only to the family's self-hosted server.

## Release workflow

`.github/workflows/ios-release.yml`: manual (`workflow_dispatch`), runs on `macos-15`, disabled
unless `IOS_RELEASE_ENABLED=true`. Steps: check configuration; compute version (digits only for
`CFBundleShortVersionString`, Android's monotonic formula for `CFBundleVersion`); import the
certificate into a temporary keychain; install and inspect the provisioning profile (team, app
id, production push); write manual-signing settings into the CI copy of `Release.xcconfig`
(not committed); optionally add the Associated Domains entitlement; `flutter build ipa
--export-options-plist`; `xcrun altool --validate-app` then `--upload-app` with the API key;
always delete keychain, profile and key files. `app/ios/ExportOptions.plist` is the template
the workflow fills (`__TEAM_ID__`, `__BUNDLE_ID__`, `__PROFILE_NAME__`).

Known weak points to watch on the first run: `altool --upload-app` is deprecated by Apple but
still works with API keys (replacement: `xcrun notarytool` is for notarisation only; for App
Store uploads the alternative is `xcrun iTMSTransporter` or fastlane `pilot`);
`method: app-store-connect` needs Xcode 15.3+ (the macOS 15 runner has it); manual signing via
`Release.xcconfig` applies to the Runner project only.

The simulator job in `test.yml` (job `ios`) now also lints the plists and runs the Swift unit
tests, which cover the software-key path of `SecureKeyChannel` (the Simulator has no Secure
Enclave) and the invite-link filter.

## Unsigned IPA for sideloading

`.github/workflows/ios-unsigned.yml` runs on every `v*` tag (and manually). On `macos-15` it runs
`flutter build ios --release --no-codesign`, zips `Payload/Runner.app` into
`orbitly-<version>-unsigned.ipa` and attaches it, plus a `.sha256` file and the SHA256 in the
release notes, to **this repository's** GitHub release for the tag. It needs no secrets, uses only
the workflow `GITHUB_TOKEN`, uploads only when the ref is a tag of `TheTractorHacker/orbitly`,
and never runs the signed `ios-release.yml` path. It waits for `apk.yml` to create the release
instead of creating one itself. Non-tag runs only keep a workflow artifact.

The file is **not installable as is**. Re-sign it yourself with AltStore or Sideloadly using your
own Apple ID, and verify the SHA256 first. Caveats of re-signing:

* A free Apple ID signs for 7 days; the app stops launching until it is re-signed (AltStore
  refreshes it while the AltServer computer is reachable). Free accounts allow 3 sideloaded apps
  and 10 App IDs per week.
* The tool replaces the bundle id and the entitlements. Capabilities that need a paid account
  or an App ID registered for them will not work: **Associated Domains** (universal invite links;
  the `openfamily://join` button still works), **Push Notifications** (`aps-environment`; the
  APNs alert and location-refresh channel will not register), and the Keychain access group.
* The Secure Enclave wrapping key may not be created, or may be lost on re-signing, because the
  Keychain items are tied to the signing identity/team. `SecureKeyChannel` then falls back to the
  software Keychain key and reports `keychain` instead of `secure_enclave`; after every re-sign
  with another identity the old wrapped secrets can be unreadable and the app asks for the
  restore phrase (fail closed).
* Not notarised or reviewed by Apple; no automatic updates (use AltStore sources or repeat the install).

## Verification status

Verified here (Linux): Dart analysis and unit tests (fake method channels, platform guards),
Go tests for the association file, plist syntax (parsed with Python `plistlib`), workflow YAML
syntax.

**Not verified, because nothing iOS can run here:** every `.swift` file compiles; the
`project.pbxproj` edits (new files are added by hand with made-up object ids); Secure Enclave
key creation, ECIES encrypt/decrypt, access-control flags and error-code mapping; behaviour
with Face ID/passcode (`recreateKey(requireUserAuth: true)`); the first-launch Keychain wipe;
blur on recording and in the app switcher; universal links end to end (needs a device, the
entitlement and Apple's CDN fetch of the association file); `tel:`/`sms:`/`otpauth:` launching;
background location, relaunch and silent-push behaviour; CocoaPods integration after the
xcconfig include fix; the privacy manifest contents against Apple's validator; the whole
signing and upload workflow.

## Options considered

| Option | Who can install | Cost / limits | Verdict |
|---|---|---|---|
| **TestFlight (internal/external)** | Up to 100 internal testers or 10,000 external via link | Paid account; builds expire after 90 days; external needs a short Beta App Review | **Recommended** |
| Ad hoc | Registered devices only (100 per year per device class) | Paid account; UDIDs; profile expires yearly | Fallback for a handful of devices |
| App Store public release | Everyone | Paid account; App Review (background location needs justification and privacy labels) | Later, if there is demand |
| Sideload (AltStore, free account) | Self | 7-day signing, 3 apps | Not supported: unreliable for an always-on tracker |

## Acceptance (not met)

"A signed build installs on a test device" and "an iPhone user can install and update the app"
both require the account above. Status: BLOCKED on the owner (Apple account), then on the first
real build, which will almost certainly need a round of fixes.
