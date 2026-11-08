# Orbitly 1.0 readiness checklist

The master checklist for submitting Orbitly 1.0 to Google Play and the Apple App Store: what must be true, who does it, the order, and the go/no-go call.

How to use it: work top to bottom, tick the boxes, and only press submit when the
[go/no-go](#8-gono-go-decision) section says GO. Each line says who owns it: **OWNER**
(you, only you can do it: accounts, money, legal, signing keys), **CI** (a workflow does
it once the owner has set the secrets), **ENG** (code or config in this repository) or
**DEMO** (the demo-server workstream, see `docs/release/DEMO_SERVER.md`). Status words:
`[x]` done and checked in this repository, `[ ]` open, `[?]` decision or unverifiable
from the build machine (needs a real phone, a Mac or a store console).

Companion pages: [Google Play](GOOGLE_PLAY.md), [App Store](APP_STORE.md),
[Store assets](STORE_ASSETS.md), [Privacy policy draft](../legal/PRIVACY_POLICY.md),
[Terms draft](../legal/TERMS.md).

## 0. Timeline reality check (read first)

| Fact | Consequence for "submit within about a week" |
|---|---|
| **Personal** Google Play developer accounts created after November 2023 must run a **closed test with at least 12 testers opted in for 14 days in a row** before Production access can be requested, then Google reviews that request (the existing listing notes this in [Google Play release preparation](../google-play-release.md)). Organization accounts do not have this rule. | If the Play account is personal, **production on Google Play cannot happen in a week**. The week can end with the closed test running. Start the 14 days on day 1. If the account is an organization account, ignore this row. |
| Apple App Review usually answers in 24 to 48 hours, but the first submission of an app that uses background location, push, and needs a server is the most likely to get questions. | Submit to Apple early in the week and keep the demo server up and monitored the whole time. |
| The Apple release pipeline (`.github/workflows/ios-release.yml`) has **never run**; the iOS app and Apple Watch app have never been built or run on a Mac or iPhone by the people who wrote them. | Budget the first CI run as a debugging session (signing). Do it on day 1, not on day 6. |
| Play and Apple need a **reachable demo server with a demo account** the whole review period (days to weeks). | The demo server must be a stable, separate server, not someone's family server. |

## 1. Product blockers (must be true before any submit)

Everything here can be checked by the owner on real phones; the repository tests cover
the logic but not the phone-specific behaviour.

- [ ] **OWNER** Install the exact release candidate (the signed APK from the tag, and the TestFlight build) on at least one Android phone and one iPhone and run the [manual test pass](#5-manual-test-pass-on-real-phones) below.
- [ ] **ENG/OWNER** No known crash: no open issue labelled crash; run the app for 24 hours with location sharing on and look at Android vitals / Xcode Organizer crash data from the closed test before promoting.
- [ ] **OWNER** SOS path verified end to end on a real phone: press SOS, the other member's phone shows the alert with a position; "Cancel" works; the screen says clearly that emergency services are NOT called. Test on Android and iPhone, with the app closed.
- [ ] **OWNER** Sign-in stability: leave a phone signed in for 48 hours with the screen locked and the server updated once in between; the person must not be signed out. The v0.25.2+ fix (concurrent refreshes of the same sign-in token get the same successor, no false "token theft" sign-outs, see [Changelog](../CHANGELOG.md), Unreleased) must be in the release.
- [ ] **OWNER** Background location on a locked phone for 30 minutes of walking on Android, and on iPhone (see the field test list in [iOS release design](../design/IOS_RELEASE.md), "Background execution on iOS"). On iPhone nothing runs when the phone is still and the app is suspended, so "last seen" can be old: this is a documented limitation; make sure the store text does not promise otherwise.
- [ ] **OWNER** Driving dashboard / driving report opens on Android with data; on iPhone the Driving detection settings say "Not available on iPhone yet" (documented, intended). Make sure no store screenshot shows iPhone driving sensors.
- [ ] **ENG** The app version shown in Settings > About matches the store version (see [Versioning](#6-versioning-policy)).
- [ ] **ENG** `flutter analyze --no-fatal-infos` has no warnings with the CI Flutter version (3.47.0), `flutter test` green, Go tests green (`.github/workflows/test.yml` green on the release commit).
- [ ] **ENG** No debug flags, no cleartext traffic, no `allowBackup`: audited, see [Audit results](GOOGLE_PLAY.md#audit-of-the-android-manifest-and-build).
- [ ] **OWNER** The in-app account deletion works on both platforms (Settings > Delete my account, with the password). Required by both stores.
- [ ] **OWNER decision** Chat has no "report message" or "block member" button. Apple guideline 1.2 expects a way to report objectionable content in apps with user-generated content. Options and the recommendation are in [App Store, guideline 1.2](APP_STORE.md#user-generated-content-guideline-12). Decide before submitting to Apple.
- [ ] **OWNER decision** Ship the **Apple Watch app** in 1.0? It has never been compiled; the signed pipeline leaves it out by default. Recommended: **not in 1.0** (add in 1.1 after one real-watch test).
- [ ] **OWNER decision** Ship the **Wear OS app** in 1.0? It builds in CI but has not been tried on a real watch (see [Watch](../user/watch.md)). Recommended: **internal testing track only for 1.0**, public after a real-watch test.
- [ ] **OWNER decision** `USE_FULL_SCREEN_INTENT` and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` in the Android manifest (see [permissions audit](GOOGLE_PLAY.md#permissions-audit)). One of them is unused and can be removed with no behaviour change.

## 2. Accounts and money (OWNER)

- [ ] Apple Developer Program membership active (99 USD/year); Team ID noted.
- [ ] Google Play Console developer account active and **identity verified**; account type known (personal or organization, decides the 14-day closed test).
- [ ] D-U-N-S number if the Apple account is an organization (not needed for an individual).
- [ ] Two-factor sign-in on both accounts; a second person with recovery access.
- [ ] Tax and "paid apps" agreements are NOT needed for a free app with no purchases. (Leave the app free, no in-app purchases, no ads.)

## 3. Store requirements per store

### Google Play (details: [GOOGLE_PLAY.md](GOOGLE_PLAY.md))

- [ ] **OWNER** Decide Play App Signing enrollment BEFORE the first upload: [enrollment choices](GOOGLE_PLAY.md#play-app-signing-enrollment-decide-before-the-first-upload). Recommended: provide the existing key so sideloaded APKs keep updating.
- [ ] **CI** Signed AAB `orbitly-<version>.aab` from a release tag (`.github/workflows/apk.yml`).
- [ ] **ENG** targetSdk meets the current Play requirement (36 with the repository Flutter, checked in the built manifest).
- [ ] **OWNER** App content declarations: privacy policy URL, ads (none), app access (demo server and account), content rating, target audience, data safety, government/financial/health (none), **location permissions declaration with video**, **foreground service declaration with video**, full-screen-intent declaration, account deletion URL.
- [ ] **OWNER** Store listing: texts in `docs/release/store-listing/en-US/`, graphics from [store assets](STORE_ASSETS.md).
- [ ] **OWNER** Closed test: 12 testers x 14 days if the account is personal.

### Apple App Store (details: [APP_STORE.md](APP_STORE.md))

- [ ] **OWNER** App ID `app.openfamily` with Push Notifications (Associated Domains only if you own the demo/production host).
- [ ] **OWNER + CI** The six secrets and the variables in [APP_STORE.md](APP_STORE.md#secrets-and-variables-the-workflow-expects); a green run of "iOS release (TestFlight)".
- [ ] **OWNER** App Privacy answers entered in App Store Connect (use [the table](APP_STORE.md#app-privacy-nutrition-label)).
- [ ] **OWNER** Export compliance answered; Info.plist now sets `ITSAppUsesNonExemptEncryption` to true (see [export compliance](APP_STORE.md#export-compliance)). **Confirm with a lawyer or the export-control authority.**
- [ ] **OWNER** Age rating questionnaire, screenshots 6.9" and 6.5" iPhone (and iPad if the app is offered on iPad), review notes with the demo account.
- [ ] **OWNER** Support URL and privacy URL live.

## 4. Legal pages, demo and assets

- [ ] **OWNER** Review and finalize [PRIVACY_POLICY.md](../legal/PRIVACY_POLICY.md) and [TERMS.md](../legal/TERMS.md) with a lawyer (they are DRAFTS). Fill the placeholders (operator name, contact email, governing law, date), remove the draft box, run `scripts/docs-check.sh --fix`, deploy. Every Orbitly server then serves them at `/privacy` and `/terms` with no sign-in.
- [ ] **OWNER** Host the final privacy policy at a public URL that stays up (Play and Apple both require it). The simplest: `https://<demo server>/privacy` (always on) or your website.
- [ ] **OWNER** Keep the existing account deletion web page live (`https://foleyit.com/delete-account.html`, saved in Play Console).
- [ ] **DEMO** Demo server up with a review family, a review account without two-step sign-in, fictional people only; URL and credentials pasted into Play "App access" and Apple "Review notes" (placeholders in `docs/release/store-listing/apple/review_notes.txt`). See `docs/release/DEMO_SERVER.md`.
- [ ] **DEMO** The demo server is on HTTPS, has APNs/push configured if you want reviewers to see an alert, and is monitored during the whole review.
- [ ] **ENG** Run `scripts/store-assets.sh`, review every image, replace by real device captures where [STORE_ASSETS.md](STORE_ASSETS.md) says to. Stores require truthful screenshots.
- [ ] **OWNER** Record the two Google Play permission videos (scripts in [GOOGLE_PLAY.md](GOOGLE_PLAY.md#video-scripts)).

## 5. Manual test pass on real phones

Do this on the exact release candidate. Two phones, two accounts, a demo or test server.

1. Install, enter the server address, create an account from an invite, accept location "Always", notifications, finish onboarding.
2. Walk or drive 10 minutes. The other phone's map follows with a delay of seconds to a minute.
3. Create a place "Home", leave and arrive: both phones get an alert.
4. Send chat text and a photo. Switch the circle to Private; chat still works; the server sees ciphertext.
5. SOS and "I'm OK" with the app closed; cancel an SOS.
6. Lock both phones for an hour; the position still updates (Android; iPhone with Always).
7. Kill the server for 5 minutes and restart it: the app recovers, nobody is signed out.
8. Change phone language/time zone, rotate the phone, dark mode.
9. Settings > Download my data, then Settings > Delete my account on a throwaway account; sign-in must then fail.
10. Uninstall and reinstall; the Android APK from the previous tag must update in place to the new tag (same signature).

## 6. Versioning policy

There are three numbers and they must not be confused.

| Thing | Where it lives | Rule |
|---|---|---|
| **Release tag** | git: `v1.0.0`, pre-releases `v1.0.0-rc.1` | The single source of truth. Never move or reuse a tag. |
| **versionName** (user visible) / iOS `CFBundleShortVersionString` | derived from the tag: `v1.0.0` becomes `1.0.0` (rc/beta suffix dropped for iOS) | Set by CI with `--build-name`. |
| **versionCode** (Android) / iOS `CFBundleVersion` | derived from the tag: `(major*1000000 + minor*1000 + patch)*100 + suffix`, suffix `99` for a final release, or the rc/beta number for a pre-release | Set by CI with `--build-number`. Examples: v0.25.2 = 2500299, v1.0.0-rc.1 = 100000001, v1.0.0 = 100000099, v1.0.1 = 100010099. |
| `version:` in `app/pubspec.yaml` | `0.1.0+1` today | **A placeholder.** CI overrides both parts on every release build, so it does not have to be edited. Only local builds without `--build-name/--build-number` use it (and the Wear OS app reads it for local builds). It is fine to leave it. |

Consequences and rules:

- Minor and patch must stay below 1000. Never reuse a versionCode: Play and App Store Connect both reject a repeated number.
- `v1.0.0-rc.N` builds always sort below `v1.0.0` (rc number < 99), so you can test release candidates on Play internal testing and still publish `v1.0.0` afterwards.
- Play requires the versionCode to increase for every upload on any track. The Wear OS AAB is built with the **same formula**, so the phone AAB and the Wear AAB get the **same versionCode**. If the Play Console rejects the Wear upload with "version code has already been used", rebuild the Wear bundle with a different code (Gradle property `-PWEAR_VERSION_CODE=<number>`, see `wear/app/build.gradle.kts`) and keep it increasing. This is untested because it needs a Play account.
- Server compatibility: the server keeps working for the last 5 *entries* of the release list in `backend/internal/compat` (`Releases`). `1.0.0` parses and sorts above `0.25.0` (checked in `compat.Parse`). When you cut 1.0, the owner adds `"1.0.0"` to that list in the release commit (this was deliberately not edited by the store-readiness work); the oldest line then drops out of the window, so tell family members on app 0.21 to update.
- Changelog: add the `## v1.0.0` section to [the changelog](../CHANGELOG.md) before tagging; the server shows it to admins.

How to release (CI does the rest): `git tag v1.0.0 && git push origin v1.0.0`. The Android workflow publishes the APKs, the AAB and `SHA256SUMS.txt`; the iOS workflow is started by hand with the same version number.

## 7. Rollout plan

### Google Play

1. **Internal testing** (up to 100 testers, no review, minutes to appear). Upload the `v1.0.0-rc.1` AAB. Install via the opt-in link on the owner's phones. Check Android vitals.
2. **Closed testing** (needed for the 12-tester rule). Create a Google Group or email list of 12+ real people, send the opt-in link, keep them opted in 14 days, collect feedback. Fix, upload `rc.2` and so on.
3. **Open testing** (optional, skipped by most apps).
4. **Production**: apply for production access (personal accounts), then create the production release from the tested AAB, start with a **staged rollout** (for example 20 percent) and watch crashes for two days before 100 percent.

Each upload to production goes through Google review (hours to a few days; the first one with background location is longer).

### Apple

1. **TestFlight internal** (up to 100 App Store Connect users, no review): run the workflow, wait 10 to 30 minutes of processing, answer export compliance, install.
2. **TestFlight external** (up to 10,000 testers, needs Beta App Review of the first build, 1 to 2 days). Use the same review notes and demo account.
3. **App Review**: attach the tested build to version 1.0, fill App Privacy, age rating, screenshots, review notes. Choose **manual release** after approval so you control the moment.
4. Phased release over 7 days is available for updates (not for the very first version).

## 8. Go/no-go decision

**GO** only when every line below is true. Anything else is NO-GO for that store.

| # | Condition | Google | Apple |
|---|---|---|---|
| 1 | Section 1 product blockers all ticked or explicitly accepted by the owner in writing | required | required |
| 2 | Release candidate installed from the store test track (not a sideloaded file) on a real phone and the manual test pass done | required | required |
| 3 | Demo server reachable from the public internet on HTTPS with the review account working, checked on the day of submission | required | required |
| 4 | Privacy policy URL, support URL and account deletion path live | required | required |
| 5 | Declarations and videos entered (location, foreground service, full-screen intent) | required | n/a |
| 6 | App Privacy, age rating and export compliance entered | n/a | required |
| 7 | 14-day closed test completed (personal account) | required | n/a |
| 8 | A named person watches the stores and the demo server for the first 72 hours after release, with the previous known-good tag ready for a rollback (halt staged rollout / pull the release) | required | required |

NO-GO triggers: any crash in the release candidate that reproduces; SOS not delivered;
sign-out loops; demo server down; privacy policy placeholders still in the text.

## 9. What was prepared in this repository and what was not

Prepared (ENG): this checklist, listing texts, Play and Apple guides, data safety and
App Privacy answers, privacy policy and terms drafts with `/privacy` and `/terms` pages on every
server, the store-asset renderer, the Info.plist purpose strings and export-compliance
key, clearer failure messages in the iOS workflow.

**Not** done and not possible from the build machine: any real-phone test, any
Mac/Xcode compile, any upload to a store console, the legal review, the demo server
(other workstream), the two permission videos.
