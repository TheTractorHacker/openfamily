# iOS app: signing, TestFlight and release decision

Issue: #52. Status: **decision recorded; signed distribution BLOCKED** on an
Apple Developer Program account (paid, 99 USD/year) and a Mac for the first
manual provisioning. Nothing here was run: no agent has an Apple account or Mac.

## Current state

- `app/ios` builds unsigned for the simulator in CI (`.github/workflows/test.yml`, job `ios`, macOS runner). Bundle id `app.openfamily`.
- No signing identity, provisioning profile, App Store Connect API key or TestFlight lane exists. No iOS push (APNs) credentials are configured by default (`APNS_*` settings exist server-side).

## Options

| Option | Who can install | Cost / limits | Verdict |
|---|---|---|---|
| **TestFlight (internal/external)** | Up to 100 internal testers (App Store Connect users) or 10,000 external via invite link | Paid account; builds expire after 90 days; external testing needs a short Beta App Review | **Recommended** for a family: invite by email/link, auto-updates through TestFlight |
| Ad hoc | Registered devices only (100 per year per device class) | Paid account; UDIDs must be registered; profile expires yearly; install needs a download page or Apple Configurator | Fallback for a handful of devices |
| App Store public release | Everyone | Paid account; App Review (location background use needs a clear justification and privacy labels) | Later, if there is demand beyond families |
| Enterprise / sideload (AltStore, free account) | Self | Free accounts: 7-day signing, 3 apps | Not supported; unreliable for an always-on tracker |

## Decision

Use **TestFlight** for family members' iPhones. Reasons: simplest update path
(satisfies "an iPhone user can install and update the app"), no per-device UDID
handling, and the same signed archive can later be submitted to the App Store.

## Requirements to unblock (human steps)

1. Enrol in the Apple Developer Program; create the App ID `app.openfamily` (or a new reverse-DNS id owned by the maintainer) with capabilities: Background Modes (location updates), Push Notifications.
2. Create an App Store Connect app record and an App Store Connect **API key** (role: App Manager).
3. Create a distribution certificate and an App Store provisioning profile (or use `fastlane match` with a private encrypted certificates repo).
4. Store as GitHub **secrets** only (never in the repo): `IOS_P12_BASE64`, `IOS_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`.
5. Fill in `NSLocation*UsageDescription` and background-location justification text (already needed for the simulator build; review wording for App Review).
6. Create `app/ios/ExportOptions.plist` (method `app-store`, team id, profile name); the skeleton workflow references it and it does not exist yet.
7. Prepare the privacy nutrition labels from `PRIVACY.md`.

## Release workflow

`.github/workflows/ios-release.yml` is a **skeleton**: `workflow_dispatch` only, disabled unless the repository variable `IOS_RELEASE_ENABLED` is `true` (set it after adding the secrets). It builds with `flutter build ipa`, signs with the imported certificate in a temporary keychain, uploads to TestFlight with `xcrun altool`/the App Store Connect API key, and removes the keychain. It has not run; expect to debug provisioning on the first real attempt.

Versioning mirrors Android (`apk.yml`): build name from the tag, build number from the same formula so builds are monotonic.

## Acceptance (not met)

"A signed build installs on a test device" and "an iPhone user can install and update the app" both require the account above. Status: BLOCKED.
