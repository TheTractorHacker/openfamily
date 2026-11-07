# Google Play release preparation

## Current status

The English listing is saved in Play Console as **OpenFamily**, with an icon,
live-map feature graphic, and five phone screenshots. The short and full
descriptions explicitly say a self-hosted server is required and explain how
to connect to one. Public production access still requires a closed test
with at least 12 continuously opted-in testers for 14 days and Google's
approval of production access.

Saved declarations include no ads, no advertising ID, not a government app,
no financial features, and no health features. The Content ratings and Health
apps declarations are actioned. The Target audience declaration includes
ages 6–8, 9–12, 13–15, 16–17, and 18+, and commits to the Families policy.
The developer confirmed the child-law compliance certification in Play
Console. The reviewer sign-in details point to the isolated review family on
`https://openfamily.frankjohnette.xyz`; credentials are stored only in Play
Console and must never be copied into this file.

Lifestyle category, support email `info@foleyit.com`, closed-test
feedback contact `info@foleyit.com`, privacy policy URL
`https://foleyit.com/privacy.html`, and account deletion URL
`https://foleyit.com/delete-account.html` are saved. Both public legal pages
now load. Data safety is saved in Publishing overview and reports that data
is encrypted in transit, matching the HTTPS-only app behavior. The Play
listing states that the app rejects HTTP server addresses and directs users
to provide an HTTPS URL. No app release has been uploaded or published; the
code and public privacy-page changes still need to ship in a release.

The Alpha closed-testing track exists but is inactive and has no release.
Its country targeting and tester list are not configured. Play Console
currently shows 0 opted-in testers. Public production access
requires at least 12 real testers continuously opted in for 14 days, followed
by Google's approval of production access.

Local release-preparation changes add an offline privacy policy before
server setup and in Settings, explicit background-location collection and
transmission disclosure, HTTPS-only networking, and signed App Bundle output
in CI. These changes have not been committed, pushed, or deployed. Validation:
107 Flutter tests pass; Flutter analysis exits successfully with informational
lint notices.

## Release build

Package: `app.openfamily`. The current Flutter SDK targets Android API 36.
Use the existing upload keystore; do not generate a replacement or expose
its private key or passwords. Never upload a debug-signed build to Play.

```sh
cd app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build appbundle --release --build-number=NEXT_UNUSED_VERSION_CODE
```

The result is `app/build/app/outputs/bundle/release/app-release.aab`.
Keep the generic server selector: do not compile in the review server URL.

The Android CI workflow now also builds a signed App Bundle and retains it
as the `openfamily-play-bundle-RUN_NUMBER` Actions artifact for manual upload.
Its APK publication behavior remains unchanged. That workflow must run with
the release-preparation changes before its bundle can be uploaded.

This Mac currently has Flutter and signing configuration but no Android SDK.
Local App Bundle generation cannot complete until the SDK is installed and
its licenses are accepted. CI already provisions its Android environment.

## Reviewer server and accounts

Use a dedicated HTTPS deployment and fictional sample data, separate from
real family locations. The proposed reviewer server is
`https://openfamily.frankjohnette.xyz`. It responds over HTTPS at `/healthz`
and serves the OpenFamily admin app; its current family list is empty. Create
review-only accounts there before entering access details in Play Console.
Do not use real family admin accounts for review.

Create two ordinary review accounts in one isolated review family, with
one designated family admin. Never give reviewers platform-admin access.
Do not require payment, an expiring invite, geographic restrictions, or an
unattended second factor to exercise the app. Keep the server reachable
throughout review, testing, and later app updates.

Enter credentials only in Play Console's private App access section. Do not
commit them, put them in this document, or include them in screenshots.

Reviewer instructions to complete once access exists:

1. Launch OpenFamily and enter the supplied HTTPS server address.
2. Tap Connect, then Log In with the supplied review account.
3. Read the location disclosure and grant the Android permissions needed
   for the background-location feature being reviewed.
4. Open the family map and People to inspect the fictional review family.
5. Open Places to create a place and configure arrival/departure alerts.
6. Install/configure ntfy as documented for the review server to test
   notifications while OpenFamily is closed.
7. Use Settings → Location sharing to stop this device reporting.
8. Use Settings → Privacy policy to read the policy, and a disposable
   account for the account-deletion flow.

## Background location declaration

Declare one core feature: **family arrival and departure alerts**.

Suggested explanation:

> OpenFamily uses background location to detect when a consenting family
> member enters or leaves a saved place, such as home or school, and notify
> their family. The phone sends location to the user's configured OpenFamily
> server while the app is closed or not in use. Foreground-only access cannot
> detect these arrivals and departures while the phone is in a pocket and
> the app is closed. Users can stop reporting using Location sharing in
> Settings or by revoking the device's location permission.

Record the production Android build, showing the prominent in-app disclosure,
the affirmative Allow Location action, the Android permission flow, creation
of a place, and an actual arrival/departure alert while the reporting app is
backgrounded. Use test devices and fictional account names; hide credentials.
Upload an accessible video and provide its link in the permissions form.
Static listing artwork is not a substitute for this functional demonstration.

Also complete any foreground-service declaration prompted by the uploaded
bundle, describing the location service and visible persistent notification.

## Data safety worksheet

Complete the form against the exact release and actual configured services.
Self-hosting does not mean no data is collected: the app transmits data off
the device to its configured server. Do not claim all traffic is encrypted
unless the release actually enforces HTTPS for all relevant connections.

| Data | Where used | Required/optional considerations |
|---|---|---|
| Precise location | Live map, history, alerts, check-ins | Location sharing/permissions can be declined |
| Approximate location | Derived from coordinates/map viewport | Review Google's precise/approximate guidance |
| Name, email, user IDs | Accounts and family membership | Account name/email required |
| Phone numbers | Optional profiles/emergency contacts/SMS | Optional |
| Photos | Optional profile avatar | Optional |
| Device or other IDs | Device registration, push endpoints | Used for app functionality |
| Other user content | Saved places, check-in/help notes | Optional feature input |
| Other data/diagnostics | Battery, motion, timestamps | Verify Google's category definitions |

Location can be viewed by same-family members and the server operator.
Optional SMS and map providers must be evaluated for data sharing and
Google's user-initiated/service-provider exceptions. No advertising or
analytics SDK is bundled. Audit records can retain IP addresses after
account deletion with user identifiers cleared; operator backups have
operator-defined retention. Do not promise instant erasure of every backup.

## Remaining publisher decisions

- Build and upload a signed App Bundle; the local Android SDK is unavailable,
  so use CI after the release-preparation branch is pushed.
- Choose closed-test countries and add at least 12 real volunteer testers.
  Start the 14-day continuous opt-in period only after the test release is
  approved and available.
- Record a functional background-location video on the production Android
  build and provide its URL in the Play declaration. Complete any foreground
  service declaration prompted by the uploaded bundle.
- Review the exact release and final Play Console changes, then explicitly
  submit them for review. Do not publish a production release before the
  required closed-test period and production-access approval.

## Official references

- [Personal-account testing](https://support.google.com/googleplay/android-developer/answer/14151465)
- [Background location](https://support.google.com/googleplay/android-developer/answer/9799150)
- [User data and privacy](https://support.google.com/googleplay/android-developer/answer/10144311)
- [Account deletion](https://support.google.com/googleplay/android-developer/answer/13327111)
- [Target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878)
