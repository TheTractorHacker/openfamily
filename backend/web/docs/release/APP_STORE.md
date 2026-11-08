# Apple App Store submission guide

Everything the owner needs to put Orbitly (bundle id `app.openfamily`) on TestFlight and the App Store: accounts, secrets, privacy answers, export compliance, review notes and screenshots.

The click-by-click account setup (enrolment, certificate, profile, API key, APNs key)
already exists in [iOS app: readiness, signing, TestFlight](../design/IOS_RELEASE.md#owner-checklist-exactly-what-to-click-and-paste);
this page does not repeat it. It adds what is needed for the **App Store** (not only
TestFlight): listing texts, App Privacy, age rating, export compliance, review notes and
the workflow variables. The master list is [Orbitly 1.0 readiness](V1_READINESS.md). Listing texts
to paste are in `docs/release/store-listing/apple/`. Honesty note: nothing on the iOS side has ever
been built, signed or run by the authors (no Mac); the first workflow run will find problems.

## Identifiers and capabilities

| Item | Value | Notes |
|---|---|---|
| iPhone app bundle id | `app.openfamily` | Explicit App ID. Capabilities to tick: **Push Notifications**. **Associated Domains** only if you own the host that serves invite links (see below). |
| Apple Watch app bundle id | `app.openfamily.watchkitapp` | Register an explicit App ID for it **only if** you ship the watch app in this version. No capabilities needed. |
| Background Modes: location, remote notifications | in `Info.plist` (`UIBackgroundModes`) | Not an App ID capability; nothing to tick in the portal. |
| App Groups | none | Not used (no widget/extension shares data). Do not add. |
| Associated Domains | optional | Orbitly is self-hosted, the server host is unknown at build time, so the default entitlements have **no** associated domains. Invite links then fall back to the landing-page button (`openfamily://`) or paste/QR. If you want `https://<your demo host>/join/...` to open the app, enable the capability on the App ID, regenerate the profile, and set the repository variable `IOS_ASSOCIATED_DOMAIN`. |
| Push (APNs) | key `.p8` for the server | Separate from the CI key; see step 7 of the IOS_RELEASE checklist. TestFlight and App Store builds use the **production** APNs host (`APNS_PRODUCTION=true` on the server). |
| Privacy manifest | `app/ios/Runner/PrivacyInfo.xcprivacy` | Present. Does not replace the App Privacy answers below. |

### Secrets and variables the workflow expects

`.github/workflows/ios-release.yml`, repository Settings, Secrets and variables, Actions.
The workflow's first step now checks all of them in one pass and prints, for each
problem, what is wrong and how to fix it.

| Name | Kind | What it is | How to create it | What the check says if it is wrong |
|---|---|---|---|---|
| `IOS_RELEASE_ENABLED` | variable | `true` allows the job to run | type `true` | job is skipped |
| `IOS_TEAM_ID` | variable | 10-character Team ID | developer.apple.com, Account, Membership details | "IOS_TEAM_ID must be the 10-character Team ID" |
| `IOS_BUNDLE_ID` | variable, optional | default `app.openfamily` | only if that id is taken | "not a valid bundle id" |
| `IOS_ASSOCIATED_DOMAIN` | variable, optional | e.g. `demo.example.com` (no `https://`) | your server host | profile has no Associated Domains: signing fails |
| `IOS_WATCH_ENABLED` | variable, optional | leave **unset** | see Apple Watch below | setting it to `true` stops the job early with an explanation |
| `IOS_P12_BASE64` | secret | Apple Distribution certificate with private key as base64 | Keychain Access, export as `.p12`, then `base64 -i cert.p12 \| pbcopy` | "missing" or "not valid base64" |
| `IOS_P12_PASSWORD` | secret | the password chosen at export | chosen when exporting | "missing" |
| `IOS_PROVISIONING_PROFILE_BASE64` | secret | App Store profile for `app.openfamily` as base64 | Profiles, App Store Connect type, download, `base64 -i x.mobileprovision` | "missing"; later steps verify team, app id (no wildcard) and production push |
| `ASC_KEY_ID` | secret | App Store Connect API key id | Users and Access, Integrations, App Store Connect API, Team Keys, `+`, role App Manager | "missing" |
| `ASC_ISSUER_ID` | secret | issuer UUID at the top of that page | same page | "must be the issuer UUID" |
| `ASC_PRIVATE_KEY` | secret | full text of the downloaded `AuthKey_XXXX.p8`, including the BEGIN/END lines | same page, download once | "must be the full text ... including the BEGIN line" |

Run it: Actions, "iOS release (TestFlight)", Run workflow, version `1.0.0` or
`1.0.0-rc.1`. The build number is derived from the version with the same formula as Android
(see [versioning policy](V1_READINESS.md#6-versioning-policy)). Do the first run early; signing
problems are normal on a first run and each step prints what it did. The workflow uploads to
**TestFlight**; promoting a build to the App Store is done in App Store Connect.

## Apple Watch

- Apple requires the watch app to be **inside** the iPhone app bundle. It is: the
  `OrbitlyWatch` target is embedded in the Runner project (companion model, watchOS 9+) and
  carries the iPhone's version numbers. Icons are in `app/ios/OrbitlyWatch/Assets.xcassets/AppIcon.appiconset`.
- The project wiring has **never been built on a Mac**. By default `ios-release.yml`
  runs `python3 scripts/ios-watch-target.py disable` and builds the iPhone app **without** the watch
  app (when `IOS_WATCH_ENABLED` is not `true`). That is the recommended v1.0 path.
- Setting `IOS_WATCH_ENABLED=true` is **not wired**: the signed build would also need an App ID
  `app.openfamily.watchkitapp`, its own App Store provisioning profile installed by the
  workflow, an extra entry under `provisioningProfiles` in `ExportOptions.plist`, and
  manual-signing settings for the watch target. None of this is implemented, so the
  workflow now stops at the first step with a message instead of failing deep inside Xcode.
  Plan it for 1.1 together with a test on a real watch (`docs/design/WATCH_APPS_APPLE.md`).
- If you do ship the watch app later: App Store Connect needs Apple Watch screenshots
  (see [store assets](STORE_ASSETS.md)).

## App Store Connect: set up the app

1. Apps, `+`, New App: platform iOS, name `Orbitly`, language English (U.S.), bundle id `app.openfamily`, SKU `orbitly`, full access.
2. Pricing: Free, all territories you want (the app has no purchases and no ads).
3. App Information: subtitle, category Lifestyle (secondary Utilities), content rights (you own or have the rights: yes), privacy policy URL (public), age rating (below).
4. Version page: description, promotional text, keywords, support URL, marketing URL, what's new, copyright: paste from `docs/release/store-listing/apple/`.
5. App Review Information: contact name, phone and email (a real person who can answer within a day) and the **review notes** from `review_notes.txt`, with the demo account filled in. Sign-in required: yes.
6. Version release: **Manually release this version** (recommended).

## TestFlight process

1. Run the workflow with `1.0.0-rc.1`. Processing in App Store Connect takes 10 to 30 minutes.
2. The build shows "Missing Compliance" until you answer the encryption questions (see below).
3. **Internal testing**: add up to 100 App Store Connect users to a group; no Apple review.
4. **External testing**: add testers by email or public link (up to 10,000). The first build of a version goes through Beta App Review (1 to 2 days); give the same review notes and demo account.
5. When the release candidate is good, create the App Store version, choose the build, submit for review. The final `1.0.0` build needs its own workflow run: build numbers must increase and the rc suffix is dropped.

## App Privacy ("nutrition label")

App Store Connect, App Privacy. Principle: Apple wants every data type that the app
sends off the device and that "you or your third-party partners" can access. The server
is run by circle administrators, and for the demo/review server by the owner; the
conservative and honest answer is to declare everything below as collected, because
the app really transmits it. The notes field lets you explain. Never answer "Data Not
Collected": the app collects.

**Do you or your third-party partners collect data from this app?** Yes.

| Apple category and type | Linked to the user's identity | Used to track | Purpose |
|---|---|---|---|
| Contact Info: Name | Yes | No | App Functionality |
| Contact Info: Email Address | Yes | No | App Functionality |
| Contact Info: Phone Number (own optional number; emergency contacts typed in) | Yes | No | App Functionality |
| Location: Precise Location | Yes | No | App Functionality |
| Location: Coarse Location | Yes | No | App Functionality |
| User Content: Photos or Videos (profile, chat) | Yes | No | App Functionality |
| User Content: Other User Content (chat messages, check-in and SOS notes) | Yes | No | App Functionality |
| Identifiers: User ID | Yes | No | App Functionality |
| Identifiers: Device ID (app-generated, push address) | Yes | No | App Functionality |
| Diagnostics: Other Diagnostic Data (app version, battery level shown as fleet health) | Yes | No | App Functionality |

**Data used to track you: none.** There is no advertising, no third-party analytics,
no data broker. App Tracking Transparency is not needed; do not add the prompt.
Advertising identifier: not used. Health & Fitness, Financial, Browsing/Search
history, Purchases, Sensitive Info, Usage Data: not collected. Contacts (address book):
not collected: the app uses the system picker and receives one chosen number.

Notes to keep consistent: `PrivacyInfo.xcprivacy` declares a `Contacts` data type and
no diagnostic type; this differs from the table above. The privacy manifest is not shown
to users; reconcile it when someone with Xcode (Product, Archive, Generate Privacy Report)
reviews it: remove `Contacts` (it describes an address book the app never reads) and add
`OtherDiagnosticData`. Not changed blind here.

## Location permission strings (guidelines 5.1.1 and 2.5.4)

`app/ios/Runner/Info.plist` now contains (reviewed and clarified in this work):

| Key | Text | Why it passes review |
|---|---|---|
| `NSLocationAlwaysAndWhenInUseUsageDescription` | "Orbitly shares your location with the people in your circles, also while the app is closed, so they can see where you are and get arrival alerts and your SOS position. Only the members of your circles see it, and you can pause or stop sharing at any time in Orbitly." | States what, who sees it, that it works in the background, and that the user controls it. |
| `NSLocationWhenInUseUsageDescription` | "Orbitly uses your location to show you on the map and, when you turn sharing on, to tell the people in your circles where you are." | Specific purpose. |
| `NSPhotoLibraryUsageDescription` | "... choose a profile photo, or a photo to send in your circle chat, from your photo library." | Now covers chat photos too (the chat picks from the gallery). |
| `NSCameraUsageDescription` | "Orbitly uses the camera to take a photo to send in circle chat." | unchanged |
| `NSFaceIDUsageDescription` | "Orbitly uses Face ID to unlock your private location map." | unchanged |
| `NSMotionUsageDescription` | "Orbitly uses motion & fitness to detect when you're driving, biking, or walking." | **No Core Motion permission is requested on iPhone today** (driving sensors are Android only), so this string is unused. Apple does not reject unused strings, but it promises something the iPhone app does not do. Recommended: remove the key until the Swift port exists. Left in place because the project documentation planned it. |

Guideline 5.1.1(iv) (do not force permissions): the permissions screen lets the user skip
every step ("Skip anyway"), and the app works in the foreground without "Always".
Guideline 2.5.4 (background services): `UIBackgroundModes` lists only `location` and
`remote-notification`, and the review notes explain the continuous-location feature. Apple
may still ask for a demo of background tracking: have a short screen recording ready.

## Export compliance

Not legal advice. **Confirm with the owner's lawyer or the export-control authority of the
country of the developer.**

What the question is about: when you upload a build, Apple asks whether the app uses
encryption, because encryption software is subject to US export rules (EAR) and rules
in some other countries (France requires a declaration for non-exempt cryptography).

Plain-words analysis for Orbitly:

1. Using **only HTTPS** (Apple's own TLS in the operating system) is exempt, and would let you answer "No non-exempt encryption".
2. Orbitly **also** encrypts data itself: end-to-end encryption of Private circles and
   chat using standard algorithms (X25519 key agreement, XChaCha20-Poly1305, HKDF, SHA-2 and Ed25519 signatures, from the Dart
   `cryptography` package, not from Apple's CryptoKit), plus Argon2 and a Secure Enclave
   key wrapper. Apple's questionnaire treats "standard encryption algorithms instead of, or in addition to, the
   operating system's encryption" as **not automatically exempt**.
3. In practice such an app is usually "mass market" encryption software that qualifies
   for a **self-classification** under the US rules (ECCN 5D992.c, License Exception ENC /
   mass-market), which means: answer *Yes, it uses encryption; it qualifies for an
   exemption only if...* then provide the documentation Apple asks for, and file a short **self-classification report
   to the US Bureau of Industry and Security (BIS) and NSA each year by 1 February** for the
   previous year (an email with a spreadsheet; no fee). Since the software is open source
   and publicly available, the "publicly available encryption source code" notification (a one-time email to
   BIS and NSA with the source URL) may apply instead. Which one fits is exactly the legal question to confirm.
4. France: apps with non-exempt crypto distributed in France may need a declaration
   (ANSSI); Apple will ask for the document or a statement. Many publishers exclude France or provide the statement.

What the repository does now: `Info.plist` sets `ITSAppUsesNonExemptEncryption` to **true**
(honest default). Effect: App Store Connect asks the export-compliance questions once
per build/version instead of silently assuming "no". Do not change it to `false` unless
the lawyer concludes that nothing the app does is non-exempt, because a false statement
is a compliance violation, not an Apple formality.

Answers in App Store Connect (typical for this app, to confirm):
- Does the app use encryption: **Yes**.
- Does it use encryption other than HTTPS/OS encryption (Apple's list): **Yes (end-to-end encryption using standard algorithms)**.
- Is it exempt under the listed exemptions: follow the lawyer's conclusion; if self-classified, upload the
  documentation requested, and note the annual report date in the calendar.

## Sign in with Apple is not needed

Guideline 4.8 requires Sign in with Apple only when an app offers **third-party or
social sign-in** (Google, Facebook, ...). Orbitly has only its own accounts (email and
password, optional passkeys and two-step sign-in) on the user's own server. So Sign in with Apple is
not required and not offered. Write this in the review notes if the reviewer asks.

## Account deletion (guideline 5.1.1(v))

Present: **Settings, Delete my account** in the app (`delete_account_screen.dart`),
confirmed with the password (and a two-step code if enabled), calls `DELETE /me`, which removes the account and its
locations, devices, contacts and messages. If the person is the last admin of a circle that still has others, the app asks
to hand over admin first; if they are the only member the circle is removed. "Download my data" (`GET /me/export`)
exists too. Mention the exact path in the review notes (done in the template). Test it once on the demo server on the day of submission.

## User-generated content (guideline 1.2)

Apps with user-generated content need: a way to filter objectionable content, a way to
**report** it with timely responses, a way to **block** abusive users, and published contact
information.

State of the app: Orbitly's only user-generated content is **circle chat** (text and photos) between
members who were invited by a circle administrator, i.e. people who already know each other. Existing controls:
circle admins can delete any message and remove any member; a member can leave; the server
administrator can suspend accounts; contact information is in the privacy policy and the support URL. There is **no
"Report" button on a message and no "Block this member" button** and no profanity filter.

Options (owner decision):

1. **Ship with the existing controls and say so in the review notes** (done in the template: invite-only
   circles of known people, admin delete/remove, support contact). Apple often accepts this for closed-group apps but can still ask for a report/block feature.
2. **Add a small "Report message" action** (long-press menu, next to Edit/Delete) that sends a note to the circle admins and the server
   operator's inbox, and a **"Mute this member's chat"** setting on the phone. About one to two days of work plus tests; recommended if you can
   afford the delay. This is a feature change, so it was **not done** in this store-readiness work.
3. Disable photo attachments for the first App Store release to reduce the risk surface (not recommended: removes a feature).

Recommendation: option 1 for the first submission with option 2 in the next version, unless the reviewer asks sooner.

## Age rating

Answer the App Store Connect questionnaire as follows (current questionnaire has
frequency options None / Infrequent / Frequent; **verify**):

| Question | Answer |
|---|---|
| Cartoon or fantasy violence, realistic violence, sexual content, nudity, profanity, horror, alcohol/drugs/tobacco, medical info, gambling, contests | None |
| Unrestricted web access | No |
| User-generated content / messaging between users | **Yes** (chat, photos in invite-only circles) |
| Advertising | No |
| Parental controls / age assurance features | No (parents are circle administrators; there is no age-gating feature) |
| Location sharing with other users | Yes (disclose in notes) |

Expect an age rating of 4+ or 9+/12+ depending on the questionnaire version; do not pick
"Made for Kids" or a Kids category, because Orbitly collects location (Kids Category
apps may not). Orbitly is not directed at children under 13.

## Screenshots and graphics (App Store Connect)

Required sizes (**verify**: Apple changes this; the 6.9" set is required for new iPhone apps, 6.5" is accepted as a fallback; smaller sets scale):

| Device class | Pixels | Required |
|---|---|---|
| iPhone 6.9" | 1320 x 2868 (or 1290 x 2796) | **Yes**, 1 to 10 images |
| iPhone 6.5" | 1284 x 2778 (or 1242 x 2688) | Yes if no 6.9" set is given, otherwise optional |
| iPad 13" | 2064 x 2752 (or 2048 x 2732) | Only if the app runs on iPad. Orbitly's project supports iPad orientations, so supply this set or restrict to iPhone |
| Apple Watch | e.g. 416 x 496 (Series 10/11 46mm), 410 x 502 (Ultra), 422 x 514 (Ultra 3) | Only if the watch app ships |
| App icon | 1024 x 1024 PNG, no transparency, no rounded corners | In the asset catalog; check `Assets.xcassets/AppIcon` |

`scripts/store-assets.sh` produces the iPhone and iPad sets with captions (see
[store assets](STORE_ASSETS.md)). Apple requires screenshots to show the real app in use:
final ones should be captured from a simulator or device (commands in that page).

## Review notes and the demo account

Template: `docs/release/store-listing/apple/review_notes.txt`. Fill the three placeholders
with the values from the demo-server work (`docs/release/DEMO_SERVER.md`). Requirements: the demo
account must work from any country, have no two-step sign-in, contain fictional data
only and stay up for the whole review and for the weeks after (Apple re-tests on updates).
Apple notes the app needs a server: the template states it first.

## Privacy policy and support URLs

- Privacy policy URL (required): the final text of [PRIVACY_POLICY.md](../legal/PRIVACY_POLICY.md) at a public URL. Every Orbitly server serves it at `https://<server>/privacy` with no sign-in; use the demo server or your own website.
- Support URL (required): a public page with a contact method (the template uses `https://foleyit.com/support`; create it).
- Terms (optional but recommended): `https://<server>/terms`. If you use the standard Apple EULA, say so; custom terms go in the App Description or EULA field.

## Order of work

1. Day 1: enrol/verify the account, create the App ID and the App Store Connect app, set the secrets, run the workflow with `1.0.0-rc.1`, fix signing.
2. Day 1 to 2: export compliance answer (lawyer), TestFlight internal test on a real iPhone, run the manual test pass.
3. Day 2 to 4: screenshots, App Privacy, age rating, listing, review notes with a working demo.
4. Submit for review; keep the demo server up; answer Apple within hours.
