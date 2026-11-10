# Google Play submission guide

Everything the owner needs to put Orbitly (package `app.openfamily`) on Google Play: signing choice, upload, every declaration with ready-to-paste text, and the videos Google asks for.

Status of the Play Console entry as of the last owner update is in
[Google Play release preparation](../google-play-release.md) (listing saved, no release
uploaded). This page is the step-by-step guide to finish it. The master list is
[Orbitly 1.0 readiness](V1_READINESS.md). Ready-to-paste listing texts are in
`docs/release/store-listing/en-US/` (title, short and full description, release notes,
category, tags, contact). Statements marked **(verify)** come from the author's
knowledge of Google's policies, which change often, and could not be checked against
the live Play Console from the build machine.

## Decisions for the owner at a glance

| # | Decision | Recommendation |
|---|---|---|
| 1 | Play App Signing: Google-generated key or the existing key | **Provide the existing key** (see below), otherwise sideloaded family phones must uninstall and reinstall |
| 2 | `USE_FULL_SCREEN_INTENT` (crash "Are you OK?" over the lock screen) | Remove for 1.0 (loud heads-up notification instead); add back later with a declaration |
| 3 | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Remove: the app never uses it (it only opens the system settings list) |
| 4 | Target audience age groups | 13 and over (the Console currently also lists 6 to 12, which brings the Families policy and its location limits) |
| 5 | Ship the Wear OS app in 1.0 | Internal testing only until tried on a real watch |
| 6 | Data safety: declare map-tile providers as "shared" | Yes, be conservative |

## Play App Signing: enrollment (decide before the first upload)

Google Play re-signs every app it serves with an **app signing key** that Google holds.
You sign the uploads with an **upload key**. You choose at the **first release upload**
(Test and release, App integrity, App signing) and **cannot undo it**.

The phones of your family today have the APK signed with this certificate:

```
SHA-256: dd3f93e62dd829e4de8137b0fe8ce179a217e05761d2338c6fa7caa3b0206b03
```

Android only installs an update over an existing app if the **signing certificate is
identical**. That decides everything:

| Choice at enrollment | What users see | Consequences |
|---|---|---|
| **A. Let Google generate the app signing key** (default for new apps), upload with your existing keystore as the upload key | The Play version is signed with a *different* certificate than the sideloaded APKs | A phone that has the GitHub/Obtainium APK **cannot update to the Play version**: Android refuses ("package conflicts with an existing package"). The person must **uninstall and reinstall**, which deletes local app data (sign-in, local caches; the account on the server is untouched, but Private-circle keys held only on that phone are lost unless the recovery phrase is used). The reverse is also true: Play users cannot take the GitHub APK. You must run two separate update channels from then on. |
| **B. Provide the existing key as the app signing key** (Console: "Export and upload a key from a Java keystore", using Google's `pepk.jar`) | Play serves apps signed with `dd3f93e6...` | **Sideloaded APKs update from Play in place and the other way round.** You hand Google a copy of the private key (encrypted for Google). Google then holds it for the life of the app. You cannot take the key back out, but you also keep your own copy. One later key upgrade is possible (for rotation after a compromise, see Play's "key upgrade"). |

**Recommendation: B**, because family members already have the sideloaded app and the
whole point of the project is that those people keep updating without a reinstall.
Choose A only if you decide that nobody on a sideloaded APK matters.

How to do B (the Console shows the exact current wording; **(verify)**):

1. Play Console, create the release (see "AAB path" below), the page asks how to sign.
2. Choose "Export and upload a key from a Java keystore". The page offers the Play
   Encrypt Private Key tool (`pepk.jar`) and an encryption public key file.
3. On a machine that has the keystore (`/home/dockhub/OpenFamily/private/keys/openfamily-release.jks`, alias `openfamily`; see [Android release process](../android-release.md)):

   ```
   java -jar pepk.jar --keystore=openfamily-release.jks --alias=openfamily \
     --output=orbitly-play-key.zip --include-cert --rsa-aes-encryption \
     --encryption-key-path=encryption_public_key.pem
   ```

   It asks for the keystore and key passwords. Upload `orbitly-play-key.zip`.
4. Afterwards check in Console, App signing: the **app signing key certificate SHA-256
   must equal `dd3f93e6...6b03`**. If it does not, stop and do not publish.
5. The upload key: the simplest correct setup is to **keep using the same keystore as the
   upload key** (the CI job signs the APK and the AAB with one key, and the sideloaded APK
   must stay on this key). Tradeoff: a leaked CI secret then leaks the app signing key
   too. If you want separation, create a second keystore for Play uploads only and teach
   `apk.yml` to sign the AAB with it (not done here; needs a CI change and a Play test).
6. Back the keystore up in two places before you hand it over (the instructions in
   [Android release process](../android-release.md) still apply).

Opt in to nothing else: leave "Play Integrity" and "Android App Bundles key upgrade"
defaults as they are.

## AAB path

- The CI job `.github/workflows/apk.yml` builds `orbitly-<version>.aab` on every `v*` tag
  and attaches it to the GitHub Release together with `SHA256SUMS.txt`. Download it from
  the release page, check the hash, upload it in Play Console (Test and release, Internal
  testing, Create new release). Do **not** upload the APKs to Play.
- Local build for a throwaway check: `cd app && flutter build appbundle --release --build-name=1.0.0 --build-number=100000099` (needs `android/key.properties`).
- The Wear OS app is a separate bundle (`orbitly-wear-<version>.aab` from `wear.yml`).

### versionCode rules

See [versioning policy](V1_READINESS.md#6-versioning-policy). In short: derived from the
tag, strictly increasing, never reused. Play refuses a versionCode that was uploaded once
on any track, even if the release was discarded. Test builds should be `v1.0.0-rc.N` tags
(they sort below `v1.0.0`).

## Target API level and 64-bit

- The app uses Flutter's defaults (`flutter.targetSdkVersion`, `flutter.compileSdkVersion`
  in `app/android/app/build.gradle.kts`). The Flutter 3.44 image used locally resolves to
  **compileSdk 36, targetSdk 36, minSdk 24**. CI uses Flutter 3.47.0, which is the same or
  newer. The wear app has `compileSdk 36`, `targetSdk 35`, `minSdk 30`.
- Google's rule (**verify**): new apps and updates must target Android 15 (API 35) since
  31 August 2025, and Android 16 (API 36) from 31 August 2026. Today (November 2026) 36 is
  required, which the phone app meets. The Wear OS app at 35 may be **below** the current
  requirement: recommended action is to raise `targetSdk` in `wear/app/build.gradle.kts`
  to 36 and run the Wear CI. This was **not** changed here because a target bump changes
  runtime behaviour and cannot be tested without a watch.
- Check the real value in the artifact you upload: `aapt2 dump badging app-release.apk | grep targetSdkVersion`
  (for an AAB: `bundletool dump manifest --bundle orbitly-1.0.0.aab | grep targetSdk`).
  The upload page of Play Console also shows a warning if the target is too low.
- 64-bit: Play requires a 64-bit build for every native-code app. A Flutter AAB contains
  `arm64-v8a`, `armeabi-v7a` and `x86_64` libraries. Check: `unzip -l orbitly-1.0.0.aab | grep 'lib/'`.
  The vendored plugins (`background_locator_2`, `driving_native`) are Kotlin only.
- 16 KB page size (Android 15+ devices, required for updates targeting 36 on 64-bit
  libraries, **verify**): Flutter 3.35+ engines are 16 KB aligned. Play Console warns at upload if not. If it does, upgrade Flutter first.

## Audit of the Android manifest and build

Read from `app/android/app/src/main/AndroidManifest.xml` and `build.gradle.kts`.

| Item | Result |
|---|---|
| `android:allowBackup` | `false`, plus `dataExtractionRules` and `fullBackupContent` that exclude everything. Good. |
| `usesCleartextTraffic` | `false`. Good. The app also refuses `http://` server addresses. |
| Debuggable | Not set in the manifest; release builds are not debuggable. Release signing refuses to build without `key.properties` (no silent debug key). |
| Minify / shrink | R8 minify and resource shrink are on for release. |
| App label and icon | `Orbitly`, `@mipmap/ic_launcher`. Good. |
| Exported components | `MainActivity` (launcher, deep links). `WatchListenerService` exported true: needed so Google Play services can deliver watch messages; it only matches `/orbitly/cmd` Wear messages and the Data Layer only delivers messages from the paired watch with the same package and signature. The widget provider and the boot receiver and `IsolateHolderService` are `exported=false`. Good. |
| Deep links | `https://<any host>/join/<code>` (no `autoVerify`, because the host is the user's own server) and `openfamily://join`. Play does not require verified app links. The app validates the link and only pre-fills a form. Fine. |
| Application id | `app.openfamily` in both the phone and the Wear app (required for the Data Layer). |
| TODO left in build file | A template comment above `applicationId`; harmless. |
| Merged manifest | See the next section (the build merges permissions from plugins). |

### Permissions audit

Checked on a real build: a release APK built from this tree (v0.25.x, debug-signed
for the check, built by the shared build helper and inspected with `aapt2 dump badging`
and `aapt2 dump xmltree`). Result: `targetSdkVersion 36`, `compileSdkVersion 36`,
`allowBackup=false`, `usesCleartextTraffic=false`, no `debuggable`, native code
`arm64-v8a armeabi-v7a x86_64`, label `Orbitly`. Final merged permission list (the
plugins add four to the ones written in the manifest):

| Permission | Where it comes from | Risk with Play | Used for | Recommendation |
|---|---|---|---|---|
| `INTERNET` | manifest | none | server connection | keep |
| `USE_BIOMETRIC` | manifest | none | optional app lock | keep |
| `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION` | manifest | needs privacy policy and data safety | map, sharing | keep |
| `ACCESS_BACKGROUND_LOCATION` | manifest | **restricted: declaration + video + review** | location while the app is closed (core function) | keep, see declaration |
| `ACTIVITY_RECOGNITION` | manifest | runtime, low | driving detection (opt-in) | keep |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` | manifest | **declaration + video (API 34+)** | background location service | keep, see declaration |
| `POST_NOTIFICATIONS` | manifest | low | alerts and service notification | keep |
| `WAKE_LOCK` | manifest | none | keep location service running | keep |
| `RECEIVE_BOOT_COMPLETED` | manifest | none | restart sharing after reboot | keep |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | manifest | **restricted use policy; unused by the code** | nothing (only the settings list is opened) | **remove (decision 3)** |
| `USE_FULL_SCREEN_INTENT` | manifest | **declaration; only calling/alarm apps by default on 14+** | crash "Are you OK?" over lock screen | **decision 2** |
| `ACCESS_NETWORK_STATE`, `VIBRATE` | plugins | none | connectivity check, alert vibration | keep |
| `USE_FINGERPRINT` | `local_auth` plugin | none (deprecated alias) | biometric lock | keep |
| `app.openfamily.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AndroidX | none | private to the app | keep |

Not present (good): `READ_CONTACTS`, any SMS or call-log permission,
`QUERY_ALL_PACKAGES`, `SYSTEM_ALERT_WINDOW`, `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`,
`MANAGE_EXTERNAL_STORAGE`, `READ_MEDIA_*` (photos use the system picker), `CAMERA`
(the camera is used through the system camera app via the image picker, which needs no
permission in the manifest as long as the app does not declare it).

Nothing was removed from the manifest as part of this work. To re-check after any
change: build the release APK and run `aapt2 dump permissions app-release.apk`.


## Data safety form

Play asks, per data type: collected, shared, optional or required, purposes; plus
security practices. Be accurate about the architecture. **The developer does not receive
any of this data.** It is sent from the user's phone to the Orbitly server that the user's
circle chose, which is run by the circle administrator (or by the owner for the demo
server). Google's definition of "collect" is "transmit off the device", whoever runs
the receiving server, so the types below are declared **collected**, and the
description box explains it.

Text for the free-text explanation field (paste):

> Orbitly is a client for a self-hosted server. Data is sent only to the server address the user enters, which is run by the user's own circle administrator. The app developer does not operate that server and receives no data. There are no analytics, advertising or crash-reporting SDKs. Private circles are end-to-end encrypted; in Normal circles the data is readable by the server operator.

| Data type (Play category) | Collected? | Shared with third parties? | Required or optional | Purposes | Notes |
|---|---|---|---|---|---|
| Precise location | Yes | No | Optional (sharing can be paused or turned off) | App functionality | Also in the background, see the declaration. |
| Approximate location | Yes | **Yes: map tile providers** (see below) | Optional | App functionality | Derived from precise location; map requests reveal the viewed area. |
| Name | Yes | No | Required | App functionality, Account management | Display name. |
| Email address | Yes | No | Required | App functionality, Account management | Sign-in. |
| User IDs | Yes | No | Required | App functionality, Account management | Account id. |
| Phone number | Yes | No | Optional | App functionality | Own optional number, and emergency contacts typed by the user (the app never reads the address book). |
| Address | Yes | No | Optional | App functionality | Place addresses typed or searched. |
| Photos | Yes | No | Optional | App functionality | Profile photo and chat photos. |
| Other in-app messages | Yes | No | Optional | App functionality | Chat; end-to-end encrypted in Private circles, readable by the operator in Normal circles. |
| Other user-generated content | Yes | No | Optional | App functionality | SOS and check-in notes. |
| Device or other IDs | Yes | No | Required | App functionality, Account management | App-generated device id and push address. **Not** the advertising ID (the app does not read it). |
| Physical activity | Yes | No | Optional | App functionality | Movement type (walking, driving, still) and driving events, if the user allows motion detection. **Owner to confirm**: declaring it is the conservative choice. |
| App info and performance: Diagnostics | Yes | No | Required | App functionality | App version, battery level, background-restriction state shown to the circle admin as fleet health. |
| Crash logs | **No** | n/a | n/a | n/a | No crash SDK; the Diagnostics screen is local. |
| Contacts (address book) | **No** | n/a | n/a | n/a | The system contact picker returns one chosen number only; no READ_CONTACTS. |
| Financial, health records, audio, files, calendar, web browsing | No | n/a | n/a | n/a | |

Shared with third parties, in detail: map tiles are fetched by the phone directly from
the tile host named by the server (by default OpenStreetMap and Esri), which sees the
viewed area and the IP address. The server-side geocoder and optional SMS or push
providers are chosen and configured by the server operator, not by the app; they do not
receive data from the phone. Google allows an exemption for service providers acting on
behalf of the developer and for user-initiated transfers; tile hosts are neither, so
declare "Approximate location: shared" to be safe.

Not declared, and why: "Keep this phone's key safe through reinstalls" (0.26.28) stores a sealed copy of the
phone's own encryption key in Google Play services Block Store. With a screen lock Block Store also backs it up to the
user's Google account, end-to-end encrypted by Google (`setShouldBackupToCloud` is true only when
`isEndToEndEncryptionAvailable()` is true). The copy goes to the user's own Google account through Google's backup, not
to the developer or any server Orbitly runs, so it is not "collected" under Play's definition (a user-initiated backup
to the user's own account). If Play review disagrees, declare "Other user-generated content / App info: not shared,
encrypted in transit and at rest, user can request deletion (the setting deletes it)".

Security practices:

- Data is encrypted in transit: **Yes** (HTTPS only; the app rejects HTTP).
- You can request that data is deleted: **Yes**. In the app (Settings, Delete my account) and on the web page required by Play: `https://foleyit.com/delete-account.html` (already saved). Both are described in the [privacy policy](../legal/PRIVACY_POLICY.md).
- Committed to Play Families policy: follow the target audience decision below; the Console currently says yes.
- Independent security review: No.

## Content rating (IARC questionnaire)

Category: choose "All other app types" / "Utility, productivity, communication" (the
form changes names; **verify**). Answers:

| Question | Answer |
|---|---|
| Violence, blood, fear | No |
| Sexual content or nudity | No |
| Profanity or crude humour | No |
| Controlled substances | No |
| Gambling (real or simulated) | No |
| User-generated content or user interaction: can users communicate or exchange content | **Yes** (circle chat with text and photos, between invited members only) |
| Does the app share the user's location with other users | **Yes** |
| Unrestricted internet access / web browser | No |
| In-app purchases / digital goods | No |
| News / government / health / finance claims | No |

Expect a low rating with the interactive-elements notes "Users interact" and "Shares
location". Do not answer "No" to the location question to get a lower rating: it is
inaccurate and grounds for removal.

## Target audience and Families policy

- Orbitly is for families and friends. It is **not designed for children under 13**, and
  a child does not run it alone: a circle administrator (parent or guardian) creates the
  child profile and manages it.
- Recommended Console answer: **13-15, 16-17, 18+**. Do **not** select 6-8 or 9-12: if
  children are in the target audience the **Families policy** applies, which (**verify**)
  restricts which SDKs, permissions and data a children's app may use and expects the app
  not to request location permissions like background location. The Console today lists
  ages 6 to 12 as well (see the status page); review that selection, because it can
  conflict with the background location approval.
- "Does the app appeal to children?" No. Explain in the privacy policy that
  children's accounts are created by guardians (done in the draft).
- A lawyer should confirm the child-account wording for COPPA (US) and GDPR-K (EU).

## Permissions and declarations

Each sensitive permission has a Play Console form (App content). Texts to paste follow.
Keep every statement true to what the app does.

### ACCESS_FINE_LOCATION / ACCESS_COARSE_LOCATION

Core function: show where family members are. Needed in the foreground for the map and
for sharing. No separate form; covered by the privacy policy and data safety.

### ACCESS_BACKGROUND_LOCATION (location permissions declaration)

Console: App content, Sensitive app permissions, Location permissions, "Background
location access". Fields:

**Core functionality (paste):**

> Orbitly is a family location-sharing app. Its core function is that the members of a private circle (for example parents and children, or friends) can see each other's current location on a map and get arrival and departure alerts for saved places such as home and school, and an SOS location. For this to work the user's own location must keep being shared with their circle while the app is closed or the phone is locked; a map that only updates while the app is open would not show where someone is, which is the whole purpose of the app.

**User benefit (paste):**

> The user's circle can see where they are without asking them to open the app, receives an alert when they arrive or leave a saved place, and can find them if they press SOS or a possible crash is detected.

**How the user is informed and consents (paste):**

> Before the system permission dialog, a full-screen "Location access" screen in the onboarding explains that Orbitly collects and sends the user's precise location to their chosen server, also when the app is closed or not in use, and who can see it. The user taps "Allow Location" to continue, then grants the system prompts and chooses "Allow all the time" in Android settings. Sharing can be paused or turned off in the app at any time, and Android shows a persistent notification while background location runs. The data is used only for the family map, alerts and history shown to the user's own circle; it is never sold, never used for advertising and not shared with third parties.

**Why foreground-only is not enough (paste):**

> Foreground-only location would stop updating whenever the phone is in a pocket or locked, so family members would see a stale position and arrival alerts and SOS positions would be wrong, which is unsafe for a safety app.

Do not claim the location is used for anything else.

### FOREGROUND_SERVICE and FOREGROUND_SERVICE_LOCATION

Console: App content, Foreground service permissions. Type: **Location**. The service
is `yukams.app.background_locator_2.IsolateHolderService` with
`foregroundServiceType="location"`.

**Description (paste):**

> The foreground service keeps a persistent notification ("Sharing your location with your circle") while the user has turned on location sharing for their circle. It runs the location updates in the background so the circle's map, arrival and departure alerts and SOS positions stay current. It starts only after the user turns on sharing and stops when the user turns sharing off. The user can stop it at any time from the notification or the app.

**User impact if it is deferred or stopped (paste):**

> Android would stop delivering location while the app is not on screen; the user's circle would see an old position and would miss arrival alerts and SOS locations.

The service is also restarted after reboot by `RECEIVE_BOOT_COMPLETED` (only if sharing was on).

### POST_NOTIFICATIONS

Normal runtime permission, no form. Used for: arrival/departure alerts, SOS and check-in
alerts, the location-service notification, chat notifications. No marketing.

### REQUEST_IGNORE_BATTERY_OPTIMIZATIONS

Google restricts this permission to apps whose core function breaks without it, and
rejects apps that use the direct "ignore battery optimization" dialog without that
justification (**verify**). **Check result: Orbitly does not use it.** The code only
opens the system list `android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS` (and the app
settings page as a fallback) in `battery_optimization_service.dart`; this works
**without** the permission. The manifest entry is therefore unused and only adds a Play
review risk. **Recommended change (not applied, owner decides):** delete these lines from the manifest:

```xml
<uses-permission
    android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

and the comment above them. No behaviour changes. If you keep it anyway, the declaration
text would be: "Core function is continuous background location; Doze stops it; the app
opens the system battery list for the user to choose, it never changes the setting itself."
The compliant alternative for the user flow (already implemented) is the
settings-list link plus the vendor autostart links from Diagnostics.

### USE_FULL_SCREEN_INTENT (crash detection prompt)

On Android 14+ Google limits this to apps whose **core function is calling or alarms**
and requires a declaration; for other apps the permission is revoked unless the user
grants it (**verify**). Orbitly uses it only for the opt-in "Are you OK?" countdown after
a possible crash (`crash_responder.dart`), shown over the lock screen. It is an
emergency prompt, not a call or alarm clock, so approval is **uncertain**. The code
already degrades: without the permission the same notification appears as a loud
heads-up with sound and vibration (the manifest comment says so).
**Options:** (1) remove the permission for 1.0 and ship the heads-up only (recommended:
no declaration, no review risk), (2) keep it and declare "emergency crash alert, user
opt-in, needs to be seen without unlocking" and accept the risk of a rejected
declaration delaying the release. Not changed here because it alters a safety behaviour.

### ACTIVITY_RECOGNITION

Runtime permission, asked only when the user turns on driving detection (motion). Used
to tell walking from driving for the circle and for the driving report. Mention it in the
data safety form (Physical activity). No Play form.

### Contacts and SMS

- **READ_CONTACTS: not requested.** The emergency-contact picker uses the system
  `ACTION_PICK` (a `<queries>` entry), which returns the one chosen number without a permission.
- **SMS permissions: none** (`SEND_SMS`, `READ_SMS`, `RECEIVE_SMS` are not in the manifest). "Text a person" opens the phone's own dialer or messaging app with `sms:`/`tel:`; SOS texts to emergency contacts are sent by the **server** through Twilio when the operator enables it. So the Play SMS/Call log restricted-permission policy does not apply.
- `QUERY_ALL_PACKAGES`: not used. The `<queries>` list names ten OEM battery/autostart packages (Xiaomi, Samsung, OnePlus, Huawei, Oppo) so Diagnostics can open the right vendor screen. That is allowed without a declaration.

### Other permissions

`INTERNET`, `USE_BIOMETRIC` (optional app lock), `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED`
and `FOREGROUND_SERVICE` are normal permissions and need no declaration.

## Video scripts

Google asks for a short public or unlisted YouTube video per declaration. Record on a
real phone (screen recording with the phone's own recorder), English, 30 to 90 seconds,
no real people's locations (use the demo circle), with on-screen captions. Link them in
the forms.

### Video 1: background location (and the foreground service)

1. Start on the home screen. Open Orbitly (fresh install on the demo server: sign in with the demo account, see `docs/release/DEMO_SERVER.md`).
2. Onboarding reaches the **Location access** screen. Pause 3 seconds on it so the text about "even when the app is closed or not in use" is readable.
3. Tap **Allow Location**. Show the Android prompt: choose "While using the app", then show the second step in settings and choose **Allow all the time**.
4. Return to the app and turn **Location sharing** on. Pull down the notification shade: show the persistent "Sharing your location with your circle" notification (this is the foreground service).
5. Press Home, lock the phone, wait a few seconds. On a **second phone** (or the web admin viewer) show the first person's marker moving on the map while the first phone is locked. Caption: "Location keeps updating while the app is closed."
6. Show an arrival alert on the second phone when the first phone arrives at the saved place "Home".
7. On the first phone: open Orbitly, Settings, turn **Location sharing** off; show the notification disappearing. Caption: "The user can stop sharing at any time."
8. Optional last frame: Settings, privacy policy.

### Video 2: foreground service (can be the same video, clearly labelled)

Show steps 4 to 7 above, with the notification pulled down, then the sharing toggle off
ending the service.

### Video 3 (only if you keep USE_FULL_SCREEN_INTENT)

Turn on crash detection in Settings, Driving detection. A real crash cannot be staged,
so use a debug or test build that fires the prompt with the phone locked and show the
full-screen "Are you OK?" countdown and the "I'm OK" button. If you cannot produce
that honestly, drop the permission (option 1) instead of faking a video.

## Wear OS submission

- The Wear OS app uses the **same package name** `app.openfamily` and is uploaded as a
  **separate bundle** in the same app: Test and release, Advanced settings, **Form
  factors**, add **Wear OS**, then create a release under the Wear OS section with
  `orbitly-wear-<version>.aab` (**verify** the current navigation).
- It is declared non-standalone (`com.google.android.wearable.standalone=false`): it
  needs the phone app. Say so in the Wear OS listing text.
- The Wear app has no INTERNET permission and asks for location only optionally (for the
  arrow to a person).
- Version codes: see the shared-versionCode note in the [versioning policy](V1_READINESS.md#6-versioning-policy).
- Required Wear OS graphics: at least one **round or square 1:1 screenshot**, minimum 384 x 384 px, no device frame, no text overlay that hides the UI (**verify**). `scripts/store-assets.sh` cannot render the watch app (it is Kotlin Compose, not Flutter); capture with the emulator (see [store assets](STORE_ASSETS.md#wear-os-round-emulator)).
- Wear OS apps must also meet the Wear quality bar (tile, complication, ambient mode). Test on a real watch before moving off internal testing.

## App access instructions for reviewers

Orbitly cannot be used without a server. Console, App content, App access: choose "All
or some functionality is restricted" and paste (replace the placeholders once the demo
server exists; see `docs/release/DEMO_SERVER.md`):

> Orbitly needs an Orbitly server. For review we run a demo server with fictional data.
> 1. Open the app. On the first screen enter the server address: DEMO_SERVER_URL_PLACEHOLDER
> 2. Sign in with: Email DEMO_ACCOUNT_EMAIL_PLACEHOLDER, Password DEMO_ACCOUNT_PASSWORD_PLACEHOLDER (no two-step sign-in).
> 3. You are in the circle "The Rivera Family" with four demo members. Check the map, Places, Chat and SOS (the demo SOS only alerts the demo circle).
> Background location: Settings > Location sharing, allow "all the time" when asked.
> Account deletion: Settings > Delete my account.

Play's **pre-launch report** logs in automatically with credentials you add in the
Console (Test and release, Pre-launch report, App access); enter the same demo account.
Do not reuse a real family's account.

## Order of work

1. Decide enrollment (A or B) and the manifest changes; merge them; tag `v1.0.0-rc.1`.
2. Create the app entry items (listing, content rating, data safety, target audience, app access, ads: none, declarations) and upload the AAB to **Internal testing**.
3. Record the videos with the rc build and submit the declarations (review can take days: start early).
4. Closed test with 12 testers for 14 days if required; then production access, then staged rollout.
