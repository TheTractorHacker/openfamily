# OpenFamily Mobile App Audit

Scope: `app/` (Flutter, Android + iOS) and vendored `app/packages/background_locator_2`, plus the backend ingest-key code the app depends on. Branch `audit/baseline`. Read-only static review; Flutter/Dart was not installed, so nothing was built or run. Items that need a device or build to confirm are labelled "needs verification". This complements `docs/audits/SECURITY_AUDIT.md` (SEC-002/SEC-003 overlap with MOB-002/MOB-003).

## Findings table

| ID | Severity | Title | Primary evidence | Effort |
|---|---|---|---|---|
| MOB-001 | High | iOS never registers the plugin-registrant callback for the background-locator headless engine; background tracking likely crashes or silently fails on iOS | `ios/Runner/AppDelegate.swift:17`, `packages/background_locator_2/ios/Classes/BackgroundLocatorPlugin.m:169-179` | S |
| MOB-002 | High | Background isolate keeps a live account bearer (access JWT) plus a never-expiring ingest key in plaintext SharedPreferences; refresh token is still pulled into the isolate as a fallback | `background_credential_store.dart:28-37,73-77`, `background_location_service.dart:190-229,339-345` | M |
| MOB-003 | Medium | Ingest key has no expiry, is not revoked on logout/password change, and is not bound to its device on the server | `backend/internal/middleware/ingest_key.go:97-136`, `handlers/auth.go:219-231`, `location_batch.go:187-196` | M |
| MOB-004 | Medium | Offline outbox stores up to 720 precise location fixes in plaintext SharedPreferences (iOS backup-eligible) | `location_outbox.dart:106-125,137-154` | M |
| MOB-005 | Medium | Server base-URL pref key collides with background credential key; logout wipes the user's configured server | `server_config.dart:15` vs `background_credential_store.dart:22,43` | S |
| MOB-006 | Medium | No R8/minify/obfuscation configured; release silently falls back to the debug signing key when `key.properties` is absent | `android/app/build.gradle.kts:138-149`, `.github/workflows/apk.yml:71-75` | S |
| MOB-007 | Medium | Outbox drain can lose points enqueued during the network call (stale read-modify-write across isolates); a poisoned newest batch pins the queue | `location_outbox.dart:160-190` | M |
| MOB-008 | Medium | Vendored `background_locator_2` is abandoned (last upstream release 2.0.6), pinned to Kotlin 1.7.20 / play-services-location 21.0.1 / gson 2.8.6 / material 1.0.0, verbose `Log.e` | `packages/background_locator_2/android/build.gradle:34-38`, `IsolateHolderService.kt:219,279,321` | L |
| MOB-009 | Medium | `flutter_secure_storage` 9.2.4 uses deprecated Jetpack EncryptedSharedPreferences; no explicit iOS Keychain accessibility class | `token_storage.dart:14-16`, `pubspec.lock` | M |
| MOB-010 | Low | Unauthenticated push body is shown verbatim as a notification; location_request commands carry no signature | `push_service.dart:177-185`, `location_refresh_service.dart:30-53` | S |
| MOB-011 | Low | BOOT_COMPLETED receiver exported without sender restriction; boot restart does not verify background-location grant | `AndroidManifest.xml:62-69`, `BackgroundLocatorPlugin.kt:206-221` | S |
| MOB-012 | Low | No `dataExtractionRules` / `fullBackupContent`; rely solely on `allowBackup=false`. iOS has no backup exclusion for prefs | `AndroidManifest.xml:40`, `Info.plist` | S |
| MOB-013 | Low | `aps-environment` hard-coded to `development` in entitlements | `ios/Runner/Runner.entitlements:11` | S |
| MOB-014 | Low | WebSocket sends the access token as a `Sec-WebSocket-Protocol` subprotocol | `family_service.dart:243` | M |
| MOB-015 | Low | Accessibility coverage is thin: only 6 files use Semantics; no explicit touch-target minimums; text scaling handled in one widget | `lib/screens`, `lib/widgets` | M |
| MOB-016 | Low | Test gaps: no tests for `ApiClient`, `TokenStorage`, background callbacks, `FamilyService`, plugin; iOS CI is simulator-debug only | `app/test`, `.github/workflows/test.yml:77` | M |
| MOB-017 | Info | Outbox cap/age mismatch (720 points vs 48 h claim), drain not pruned by age, dedupe by `ts` only | `location_outbox.dart:122-130` | S |
| MOB-018 | Info | Debug manifest allows cleartext for an emulator http URL that Dart code rejects anyway | `debug/AndroidManifest.xml:5`, `secure_url.dart` | S |

---

## 1. Secure storage and background credential flow

### What is stored where (verified from source)

| Datum | Location | Protection | Reader |
|---|---|---|---|
| access JWT (15 min), refresh token (30 d, rotating), device id | `flutter_secure_storage` (Android: EncryptedSharedPreferences/Keystore; iOS: Keychain, default accessibility) `token_storage.dart:14-16,96-98,105-122` | Keystore/Keychain | foreground app; background isolate only on fallback (refresh token) |
| Mirror: API base URL, **access JWT**, device id | SharedPreferences keys `wb_api_base_url`, `wb_access_token`, `wb_device_id` (`background_credential_store.dart:22-37`) | none (plaintext XML / NSUserDefaults plist) | background isolate |
| **Ingest key** (device-scoped, never expires) | SharedPreferences `wb_ingest_key` (`background_credential_store.dart:73-77`, written at `device_service.dart:55-58`, `ensureIngestKey` `device_service.dart:69-80`) | none | background isolate |
| Server URL (user-chosen) | SharedPreferences `wb_api_base_url` (`server_config.dart:15,50`) | none (not a secret) | all |
| Offline location queue (precise lat/lon/ts/battery) | SharedPreferences `location_outbox_v1` (`location_outbox.dart:120`) | none | both isolates |
| Processed push request ids, push-enabled pref, theme | SharedPreferences | none | n/a (low sensitivity) |
| Biometric lock flag | via `BiometricService` (not traced in detail) | needs verification | n/a |

### Background flow
1. Login -> `TokenStorage.saveTokens` writes the secure store and mirrors base URL + access token + device id into prefs (`token_storage.dart:106-122`).
2. Device registration returns the ingest key once; it goes to prefs (`device_service.dart:44-60`). Pre-existing devices get one via `POST /devices/{id}/ingest-key` from `map_screen.dart:342-345`.
3. Native `background_locator_2` calls Dart `onLocationUpdate` / `onHeartbeatTick` in a headless isolate (`background_location_service.dart:58-110`). `_report` sends `X-Device-Key: <deviceId>.<key>` first (`:164-175`), and on 401/403 or absent key falls back to `Authorization: Bearer <access>` and, on 401, reads the **refresh token from secure storage in the background isolate**, calls `/auth/refresh`, and tries to write the rotated pair back (`:207-229,339-385`).
4. Failures enqueue to the outbox; success triggers a drain through `/locations/batch` (`:92-106,238-275`).

### Attacker capability
- **Rooted device / adb on a debuggable build / forensic image of app data:** can read `FlutterSharedPreferences.xml`: server URL, device id, a (usually expired) access JWT, the **ingest key** (valid indefinitely), and up to 720 recent precise locations. With the ingest key + device id they can forge location reports for that device from anywhere (and, per MOB-003, for any other device of the same user). The Keystore-wrapped secure store is not readable off-device, but on a rooted live device Frida/runtime hooks can pull the refresh token.
- **Backup attacker:** Android: `allowBackup="false"` (`AndroidManifest.xml:40`) blocks adb/cloud backup (checked, fine). iOS: `NSUserDefaults` (`Library/Preferences/*.plist`) is included in iCloud and iTunes/Finder backups by default; Keychain items with the default `WhenUnlocked` accessibility are migrated to encrypted backups. So an iOS backup exposes the ingest key, server URL and outbox location history. No code sets `isExcludedFromBackup` (needs verification of the native side; nothing found in `ios/Runner`).
- The comment at `background_credential_store.dart:66-72` claims secure storage is unreliable in the headless isolate. On Android the plugin builds `FlutterEngine(context)` (`IsolateHolderService.kt:71`) which auto-registers plugins, so secure storage should be reachable there (needs verification on device). On iOS plugin registration depends on MOB-001, and the default `WhenUnlocked` Keychain class makes reads fail while the phone is locked, which is the real reason iOS background reads of the refresh token fail.

### MOB-002 (High) Reusable credentials in the background isolate
- Evidence: `background_credential_store.dart:28-37` (access JWT mirrored plaintext), `:73-77` (ingest key plaintext), `background_location_service.dart:207-229,339-345` (refresh token read in isolate), `token_storage.dart:226-235` (background-supplied access token is written back into the secure store, so a prefs-planted token revives a session).
- Scenario: rooted phone or iOS backup yields the ingest key (permanent) and, within 15 minutes of use, an access JWT valid for every read API (family locations, history). `hasStoredSession()` (`token_storage.dart:136-145`) also treats the plaintext access token as proof of a session.
- Recommended fix / migration design (below).
- Effort: M. Acceptance: (a) `grep wb_access_token` returns nothing in `lib/`; (b) background isolate code path never references `TokenStorage`/`/auth/refresh`; (c) on a rooted emulator, `shared_prefs` contains no token or key; (d) background reporting survives 24 h with the app closed on Android and a locked iOS device; (e) unit tests cover migration from legacy prefs.

#### Migration design: device-scoped credential only in the background isolate
1. **Server (prerequisite, see MOB-003):** make the ingest key a first-class device credential: bound to `device_id` (reject `device_id` mismatch in body), revoked on `POST /auth/logout`, on device delete and on password change, optional sliding expiry (e.g. 90 days) with rotation: when a request uses a key older than N days, respond with header `X-Device-Key-Next: <new key>` that the client stores atomically. Scope: only `/locations`, `/locations/batch`, `/devices/heartbeat`. Add per-key rate limiting.
2. **Client storage:** store `{baseUrl, deviceId, ingestKey}` in Keystore/Keychain, not prefs.
   - Android: `flutter_secure_storage` (or, preferably, a small native Keystore-backed AES-GCM blob owned by the vendored plugin so the headless engine and boot path share it).
   - iOS: Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device)`), so reads work while locked after first unlock and the item is excluded from backups/migration.
   - Keep the foreground account tokens in a separate Keychain/Keystore namespace; do not share.
3. **Remove** the access-token mirror (`sync` access param), `_refresh`, `_readRefreshToken`, the Bearer fallback in `_report`/`_sendLocationBatch`, and `syncFromBackgroundStore`. On 401/403 from the ingest key: stop posting, set a "needs re-auth" flag, and show a local notification asking the user to open the app; the foreground then calls `rotateDeviceIngestKey` with its own session.
4. **Rollout:** release N: write the key to secure storage and read secure-first with fallback to legacy prefs (read-through copy then delete the pref); stop writing `wb_access_token` and delete it on startup; ensure `ensureIngestKey` runs at every foreground start so older devices get a key. Release N+1: delete the fallback code and the legacy prefs reader. Keep server accepting Bearer on ingest routes for one more release for N-1 clients, then remove.
5. **Outbox:** keep only a minimal queue, encrypt at rest or move to a private file excluded from backup (see MOB-004).

### Checked and fine
- Refresh token is not mirrored to prefs (`token_storage.dart:112-121`).
- `TokenStorage.clear` is verified-delete with fail-safe lock behaviour (`:152-195`) and clears outbox and ingest key via `BackgroundCredentialStore.clear` (`:39-46`).
- Server stores only SHA-256 of the ingest key and compares in constant time (`ingest_key.go:37-60`); the key is 256-bit random. SHA-256 without salt is fine for high-entropy secrets.

---

## 2. Android

| Item | Result | Evidence |
|---|---|---|
| allowBackup | `false`, good | `AndroidManifest.xml:40` |
| dataExtractionRules / fullBackupContent | absent (MOB-012). With `allowBackup=false` Android 12+ device-to-device transfer is also disabled, but explicit rules are the documented safeguard (needs verification per OEM) | manifest |
| Cleartext | `usesCleartextTraffic="false"` in main, good. Debug manifest enables it (`debug/AndroidManifest.xml:5`) which is debug-only (MOB-018) | |
| network_security_config | none; defaults on targetSdk >= 28 deny cleartext and trust only system CAs (user CAs not trusted for API 24+ apps). No pinning | no `res/xml` |
| Exported components | `MainActivity` exported (required, launcher). `BootBroadcastReceiver` `exported=true` with BOOT_COMPLETED filter (MOB-011); `IsolateHolderService` `exported=false`; plugin receivers `exported=false` (`background_locator_2/android/src/main/AndroidManifest.xml:5-11`). No custom intent filters, deep links or content providers found | |
| Service type | `foregroundServiceType="location"` with `FOREGROUND_SERVICE_LOCATION` permission, correct for API 34+ (`AndroidManifest.xml:16,75`). `startForeground(id, notification)` is called without a type argument (`IsolateHolderService.kt:142,148`), which falls back to the manifest type; fine on API 34, needs verification on API 35. The odd `android:permission="android.permission.FOREGROUND_SERVICE"` on the service (`:73`) is harmless but unnecessary | |
| Permissions | INTERNET, USE_BIOMETRIC, COARSE/FINE/BACKGROUND location, ACTIVITY_RECOGNITION, FOREGROUND_SERVICE(+LOCATION), POST_NOTIFICATIONS, WAKE_LOCK, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, RECEIVE_BOOT_COMPLETED. All have a use. `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is Play-policy sensitive but acceptable for a safety/tracking app with a declared justification. No READ_CONTACTS (good) | `:3-25` |
| Signing | release signs with the `release` config only if `key.properties` exists, else **debug key** (MOB-006) | `build.gradle.kts:121-149` |
| R8/ProGuard | none: no `isMinifyEnabled`, `isShrinkResources`, or proguard file; `flutter build` in CI has no `--obfuscate --split-debug-info` | `apk.yml:71-75` |
| Misc | `applicationId` still has a template TODO comment (`build.gradle.kts:105`); `minSdk/targetSdk` follow Flutter defaults (needs verification of resolved values for Flutter 3.47) | |

### MOB-006 (Medium) Release hardening
- Scenario: a build run without `key.properties` (local, fork CI, mis-set secret) produces a release APK signed with the public debug key, which can be impersonated/updated over by anyone; unshrunk, unobfuscated Dart/Java eases reverse engineering of endpoints and credential handling.
- Fix: fail the release build if `key.properties` is missing in CI (`error(...)` when `System.getenv("CI")` is set); enable `isMinifyEnabled = true`, `isShrinkResources = true` with a `proguard-rules.pro` keeping Flutter and the plugin classes (`yukams.app.background_locator_2.**`, gson models); add `--obfuscate --split-debug-info=build/symbols` and archive symbols.
- Effort S. Acceptance: release build without keystore fails; `apkanalyzer` shows renamed classes; background tracking still starts after R8 on a device smoke test.

### MOB-011 (Low) Boot receiver
- `BootBroadcastReceiver` is exported without `android:permission="android.permission.RECEIVE_BOOT_COMPLETED"`. The action check (`BootBroadcastReceiver.kt:8`) prevents other apps from triggering with a different action, but any app can send an explicit `BOOT_COMPLETED` intent (the action is not protected for explicit delivery to an exported receiver on all versions). Effect is limited to starting the app's own tracking service, which then re-checks only FINE_LOCATION (`BackgroundLocatorPlugin.kt:215-219`), not background grant, and not whether the user logged out (settings persist in plugin prefs; `stop()` should clear them, needs verification).
- Fix: add `android:permission="android.permission.RECEIVE_BOOT_COMPLETED"` to the receiver, also handle `LOCKED_BOOT_COMPLETED`/`MY_PACKAGE_REPLACED` deliberately, require `ACCESS_BACKGROUND_LOCATION` and a stored session. Effort S. Acceptance: `adb shell am broadcast -n .../BootBroadcastReceiver -a android.intent.action.BOOT_COMPLETED` from the shell/another app is rejected; reboot test restarts tracking only when logged in.

### Restart after reboot
Implemented: `registerAfterBoot` re-initializes and starts the isolate service from stored settings (`BackgroundLocatorPlugin.kt:206-221`); service restarts itself after process death via `START_STICKY` with stored settings (`IsolateHolderService.kt:219-237`); heartbeat alarm covers silent periods. Android 15 restrictions on starting a `location` FGS from a boot receiver are needs verification on-device. The credentials it needs (prefs) are available after boot, but under MOB-002's migration the Keystore blob must be readable before first unlock only if using direct-boot-aware storage; plan for `first unlock` instead (BOOT_COMPLETED fires after unlock for credential-encrypted storage, so this is fine).

---

## 3. iOS

| Item | Result | Evidence |
|---|---|---|
| Background modes | `location`, `remote-notification` | `Info.plist:55-59` |
| Usage strings | WhenInUse, AlwaysAndWhenInUse, Motion, Photos, FaceID present. `NSLocationAlwaysUsageDescription` (legacy iOS < 11) absent, irrelevant at deployment target 15.0 | `Info.plist:43-54`, `project.pbxproj:363` |
| ATS | no `NSAppTransportSecurity` key, i.e. default (HTTPS only), good | |
| Entitlements | only `aps-environment=development` (MOB-013). No keychain-access-groups, no associated domains, no app groups. Comment claims automatic signing flips to production for distribution builds; that is true for Xcode-managed archives but needs verification of CI/export options | `Runner.entitlements:11` |
| Keychain accessibility | `FlutterSecureStorage` constructed with no `iOptions` (`token_storage.dart:14-16`) so the package default (`unlocked` = WhenUnlocked) applies: not readable when locked (breaks background refresh) and included in encrypted backups (MOB-009) | |
| AppDelegate | Silent push handler forwards `userInfo["of"]` to Dart (`AppDelegate.swift:71-83`); the `didReceiveRemoteNotification:fetchCompletionHandler` is not an `override` which the comment justifies; works because Flutter app delegate does not declare it, but there is no registered `UIBackgroundModes: fetch`, so only `content-available` pushes with remote-notification apply (OK) | |
| PrivacyInfo.xcprivacy | not found in `ios/Runner` (required by Apple since 2024 for required-reason APIs such as UserDefaults/file timestamps; third-party SDK manifests may cover pods) | needs verification |

### MOB-001 (High) iOS background engine never gets plugins registered
- Evidence: the plugin's `startLocatorService` asserts and then **calls** the static `registerPlugins` block (`BackgroundLocatorPlugin.m:169-179`). It is set only via `+setPluginRegistrantCallback:` (`:31-32`). A repo-wide grep finds no call to `setPluginRegistrantCallback` in `ios/` or `lib/`; `AppDelegate.swift:17` only registers with `self`.
- Scenario: in Release builds `NSAssert` is compiled out, so invoking the nil block crashes the app (EXC_BAD_ACCESS) as soon as the user grants Always and `BackgroundLocationService.start()` runs; in Debug it raises an assertion. Even if guarded, the headless engine would lack `shared_preferences`, `battery_plus`, `http` bindings so `onLocationUpdate` would throw into its blanket `catch (_) {}` (`background_location_service.dart:107-109`) and report nothing silently. Not exercised by CI (`flutter build ios --simulator --debug` only).
- Fix: in `AppDelegate`, `import background_locator_2` and call `BackgroundLocatorPlugin.setPluginRegistrantCallback { registry in GeneratedPluginRegistrant.register(with: registry) }` before `super.application(...)`; add a nil guard in the plugin. Add a TestFlight smoke test for background reporting.
- Effort S. Acceptance: on a physical iPhone, with Always granted and app swiped away, locations arrive server-side for 1 h; no crash on `start()`; added log/test asserting the callback is set. Needs verification on device (static analysis only).

---

## 4. Vendored `background_locator_2`

- Version 2.0.6, copyright REKAB 2020 / Yukams 2022 (`pubspec.yaml`, `LICENSE`): **MIT**, permissive; the repo must retain the notice (it does, `packages/background_locator_2/LICENSE`). Upstream is abandoned (app `pubspec.yaml:65-68` says so; changelog ends at 2.0.6, ~3 years old).
- Local patches evident: jcenter removed, namespace added, Kotlin null fix, plus substantial in-house additions (heartbeat alarm, activity transitions, `activeInstance`, `restartFromStoredSettings`). So this is effectively a fork the project owns; no patch log or diff against upstream exists (needs a `PATCHES.md`).
- Dependencies outdated (MOB-008): `kotlin-stdlib-jdk7:1.7.20`, `play-services-location:21.0.1`, `gson:2.8.6` (known CVE-2022-25647 deserialization DoS fixed in 2.8.9), `material:1.0.0` (ancient; unused UI risk and AndroidX conflicts) (`android/build.gradle:34-38`).
- Logging: `Log.e` used for routine lifecycle events (`IsolateHolderService.kt:219,279,321,355`); 16 `Log.*` call sites in the plugin. Checked: none log coordinates in the grepped lines, but a full review of all 16 is needs verification.
- Battery: 60 s interval at HIGH accuracy with `wakeLockTime: 60` and a partial wakelock per update (`IsolateHolderService.kt:171-176`); stationary drop to low-power profile via activity transitions (`ActivityTransitionsManager`), plus a heartbeat alarm. Battery-optimization exemption is requested through `BatteryOptimizationService`. Reasonable; real drain needs measurement.
- Permission handling: the Dart side only starts when `LocationPermission.always` (`background_location_service.dart:417-421`); native service re-checks FINE+COARSE after restart and stops if missing (`IsolateHolderService.kt:227-231`). It does not check `POST_NOTIFICATIONS` (service still runs; notification may be suppressed) and boot path checks only FINE (MOB-011).
- iOS: `pausesLocationUpdatesAutomatically = NO`, significant-change monitoring for relaunch after termination (`BackgroundLocatorPlugin.m:77,157,220`) which is the correct recovery mechanism; depends on MOB-001.
- Risk: the fork must be maintained for each Android/iOS OS release (API 35/36 FGS changes). Fix (MOB-008): bump native deps (gson >= 2.10, play-services-location current, drop material), add `PATCHES.md`, add Kotlin unit tests for restart logic, and evaluate replacing the plugin with `geolocator` + a native foreground service/`flutter_background_service` long term. Effort L. Acceptance: dependency check (OWASP/`gradle dependencyUpdates`) shows no known vulnerable artifacts.

---

## 5. TLS and URL handling

- `secure_url.dart:5-23`: `isHttpsUrl` / `normalizeHttpsBaseUrl` require scheme `https`, a host, no userinfo/query/fragment. Verified applied to: stored URL (`server_config.dart:27-35`), user entry (`:41-47`), dart-define hint, tile URLs (`tile_config.dart:32-37`), ntfy base URL (`push_service.dart:127-131`). Existing tests: `test/services/secure_url_test.dart`, `server_config_test.dart`.
- Checked: no `badCertificateCallback`, no `HttpOverrides`, no `SecurityContext` or `http://` literals anywhere in `lib/` (grep clean). Background isolate builds URLs from the stored base URL via `Uri.parse` (`background_location_service.dart:329`) without re-validating https; a tampered pref (root attacker) could redirect credentials. Add `normalizeHttpsBaseUrl` in `_readCredentials` (Low, S).
- WebSocket scheme is derived from the base URL (`family_service.dart:479-483`) so it is wss only because the base is https.
- No certificate pinning. Appropriate for self-hosted (operators bring own certs); document the tradeoff. Optional: allow user-trusted private CA pinning for LAN deployments. Info.
- Redirects: `package:http` follows redirects for GET; a redirect from https to http is possible for a hostile server, but it is the user-chosen server. Info.
- Map tiles use OSM and Esri by default (`tile_config.dart:6-12`), disclosing viewport coordinates and IP to third parties; `userAgentPackageName` is set (`map_screen.dart:659`), satisfying the OSM policy. Privacy note, not a vulnerability.
- MOB-014 (Low): token in `Sec-WebSocket-Protocol` (`family_service.dart:243`) is a common workaround but is logged by some proxies and echoed in server responses; prefer a short-lived one-time ws ticket from `POST /ws/ticket`. Effort M; acceptance: access JWT never appears in proxy logs of the WS upgrade request.
- MOB-018 (Info): `debug/AndroidManifest.xml:5` permits cleartext for `http://10.0.2.2` but the app rejects http URLs, so local emulator dev cannot use it as the comment suggests. Remove or add an explicit debug-only exception.

---

## 6. Push (UnifiedPush / APNs)

- Android: `unifiedpush` 6.2.0; distributor chosen automatically, preferring one containing "ntfy" (`unifiedpush_bridge_io.dart:44-57`). Endpoint is sent to the backend via `PATCH /devices/{id}` (`push_service.dart:157-166`). The ntfy base URL comes from the server's config and must be https (`:127-131`).
- Payload exposure: commands are `{"type":"location_request","request_id","expires_at"}` (`location_refresh_service.dart:30-53`) which expose no location, only a request id. Other pushes (alerts for SOS/check-in/help) are shown from the raw body (`push_service.dart:177-185`), so the text of family alerts transits the ntfy/UnifiedPush server in clear to that operator (end-to-end encryption/Web Push VAPID is not used here; `unifiedpush` supports it, needs verification of backend). Recommend a generic body ("New alert, open OpenFamily") with fetch-on-open, or WebPush encryption.
- MOB-010 (Low): anyone who learns the endpoint URL can push arbitrary text that the app displays (only when foregrounded: `showForeground` returns early unless resumed, `:104-106`, so background-delivered text is rendered by the distributor, not the app) and can trigger `location_request` handling. Commands are expiry-checked and de-duplicated (32-id ring, `:148-206`), respect the sharing toggle and refuse mocked locations, so a forged command can at most cause an extra location report to the user's own server, i.e. battery/data abuse plus a "requested" row. Fix: include an HMAC (device-ingest-key-derived) in command payloads, validate length of `body` before display, sanitize/limit to 200 chars. Effort S.
- `handlePush` runs in the foreground isolate via `ApiClient` (Bearer + secure storage); on Android when the app is dead the distributor delivers to the app process, which requires the app's Dart runtime; on iOS a locked device cannot read WhenUnlocked Keychain tokens (MOB-009), so silent refresh may fail until unlock.
- iOS: silent pushes are accepted only if `userInfo["of"]` is a string (`AppDelegate.swift:76`); alert banners only shown in foreground via delegate (`:90-100`). APNs token (hex) is sent to the server over the authenticated API. `UNUserNotificationCenter` usage is fine.
- Notification lock-screen content on iOS alerts is determined by the backend payload (needs verification in backend APNs code: ensure no coordinates in the alert body).

---

## 7. Offline outbox correctness

Checked behaviour (`location_outbox.dart`) and tests (`test/services/location_outbox_test.dart`, 211 lines):
- Dedupe by `ts` string on enqueue (`:142-144`) and on removal (`:173-178`). OK within one device; a ts string format difference (e.g. `Z` vs `+00:00`, fractional digits) between background and foreground reporters would defeat dedupe, but server dedupes by `(device_id, ts)` too (`location_batch.go:248`, pre-query not `ON CONFLICT`: needs verification that a unique index exists, otherwise concurrent retries can duplicate).
- Ordering: batch is selected **newest first** (`:57-65`) and server comparison is skipped on backfill; a member's `member_positions` upsert needs to ensure the newest ts wins (batch handler comment lines 35: "can never move the family map backwards"), OK.
- Size cap: 720 points, 48 h age (`:122-130`). Prune only occurs at enqueue (`:148`); a drain leaves expired points until the next enqueue (MOB-017). 720 x 60 s is 12 h, not the stated 48 h age; text at line 122 is accurate, line 130's rationale is not.
- MOB-007 (Medium): `drain` reads the list, awaits `send` (up to 15 s `_httpTimeout`), then writes `remaining` computed from the **pre-send snapshot** (`:167-185`). Any point enqueued by the other isolate during that window is overwritten and lost. The class comment (`:106-114`) calls this "milliseconds wide"; with network latency it is seconds. Also a poisoned batch: a permanent 4xx for the newest 100 (for example one invalid point) returns false forever and blocks older points until they age out at 48 h. Fix: re-read inside the removal step (`prefs.reload()` then filter by sent ts), drop the batch and bisect on 400, or use the batch response's per-point rejected list. Effort M. Acceptance: unit tests with concurrent enqueue-during-send keep the new point; a 400 batch does not block subsequent batches.
- MOB-004 (Medium): queue holds precise coordinates in plaintext prefs; every enqueue rewrites the whole JSON string (O(n), up to ~300 KB) which is also costly on battery. Fix: store in an app-private file/SQLite with `NSFileProtectionCompleteUntilFirstUserAuthentication` and backup exclusion; or encrypt with a Keystore key; cap by bytes. Effort M. Acceptance: no coordinates in prefs; file has the exclusion attribute; queue survives process kill.
- Logout clears the queue (`:204-219`, called from `token_storage.dart:173`). Verified in tests (`background_credential_store_test.dart`).

---

## 8. Dependency age (`pubspec.yaml`, `pubspec.lock`)

Locked versions seen: flutter_secure_storage 9.2.4, geolocator 13.0.4, http 1.6.0, unifiedpush 6.2.0, flutter_local_notifications 22.3.0, battery_plus 6.2.3, permission_handler 11.4.0, local_auth 2.3.0, flutter_map 7.0.2, shared_preferences 2.5.5, web_socket_channel 3.0.3, share_plus 10.1.4, connectivity_plus 6.1.5, image_picker 1.2.3. CI pins Flutter 3.47.0; lockfile SDK constraint Dart >=3.12 vs `pubspec.yaml` `>=3.4.0`: inconsistent lower bound (Low; needs verification that the declared range is actually buildable).
- Behind current majors (needs verification of the exact latest on pub.dev as of today, 2026-10-25, since no network check was run): `flutter_secure_storage` (v10 line exists, migrates off deprecated EncryptedSharedPreferences), `geolocator` (13 -> newer), `flutter_map` 7 -> 8, `share_plus` 10 -> newer, `permission_handler` 11 -> 12, `battery_plus` / `connectivity_plus` / `flutter_lints` ^4 (current 5/6).
- MOB-009 (Medium): `flutter_secure_storage` 9.x on Android relies on `androidx.security:security-crypto` (deprecated). Plan upgrade to the current major with the new cipher defaults and an in-place data migration (old data read on first launch and rewritten), and set explicit iOS `accessibility: first_unlock_this_device`. Effort M. Acceptance: upgrade test from a 9.x-written store retains the session; iOS background read works with device locked after first unlock.
- `dependency_overrides` of `background_locator_2` to the path (acceptable, documented).
- No automated dependency/CVE scanning in workflows (`.github/workflows` has apk, test, pages, ca-trust, web-preview). Recommend Dependabot for pub, gradle, and GitHub Actions (Low, S).

---

## 9. Accessibility basics (MOB-015, Low)

Evidence: `Semantics`/`semanticsLabel` appear in only six files (profile, sos, member_list_sheet, member_avatar_bubble, biometric_app_lock, map_bottom_bar, circle_switcher by grep; 24 total mentions); 21 `IconButton`s and 21 `tooltip:` mentions suggests most icon buttons are labelled (good), but `GestureDetector`/`InkWell` appear 19 times, and custom tappables there often lack labels. Text scaling: `AndroidManifest` handles `fontScale` config changes; explicit `MediaQuery.textScalerOf` use only in `member_list_sheet.dart:38-40`; fixed sizes (e.g. `width: 20/28` indicators) exist but are spinners/icons. No evidence of 48x48 dp minimum enforcement for custom controls (map markers, `member_avatar_bubble`, bottom bar). Not exhaustively reviewed; contrast not assessed. SOS screen has Semantics (good for a safety-critical flow).
- Fix: add labels to every GestureDetector/InkWell target, wrap map markers with `Semantics(button: true, label: member name + status)`, enforce `MaterialTapTargetSize.padded`/`ConstrainedBox(minWidth/minHeight: 48)`, add widget tests with `textScaler: TextScaler.linear(2.0)` and `meetsGuideline(androidTapTargetGuideline)` / `labeledTapTargetGuideline` for main screens. Effort M.

---

## 10. Architecture, state management, tests

- Architecture: `lib/{main.dart, models, screens, services, widgets, theme, utils}`. Services are static singletons (`ApiClient`, `TokenStorage`, `ServerConfig.instance`, `TileConfig.instance`, `FamilyService` with `ChangeNotifier`-style listeners), screens are mostly `StatefulWidget` + `setState`/`ValueNotifier`/`FutureBuilder`. No Provider/Riverpod/Bloc in `pubspec.yaml`. Consequences: low dependency surface, but static globals make testing hard (see test gaps) and cross-isolate state (prefs) is hand-synchronized. Large files: `map_screen.dart` 1090 lines, `sos_screen.dart` 850, `profile_screen.dart` 806, `api_client.dart` 773 (monolithic, no typed models for all endpoints).
- Session handling: `session_gate.dart` plus `ApiClient` single-flight refresh and `onSessionExpired` callback; biometric app lock (`biometric_app_lock.dart`, `biometric_service.dart` with 409-line test, good).
- Tests: 36 test files, ~4,000 lines in `app/test`: models, screens (welcome, settings, SOS, safety, permissions, place picker...), services (outbox, credential store, session gate, secure_url, server_config, push, biometric, member_mapper) and widgets. CI runs `flutter analyze` and `flutter test` (`test.yml:53-55`) and a simulator debug iOS build.
- MOB-016 gaps: no tests for `ApiClient` (401/refresh/retry matrix), `TokenStorage` (clear/verify paths), `background_location_service.dart` (`_report` fallback logic, status handling), `FamilyService` websocket reconnect, `LocationReporter`, `DeviceService`, the vendored plugin (one 16-line placeholder test), nor any integration/E2E or native Kotlin/Swift tests. Fix: inject an `http.Client` into `ApiClient` and the background reporter; add table-driven tests; add Android instrumented smoke test for restart; add device-farm/TestFlight smoke for iOS background. Effort M-L. Acceptance: coverage report in CI with a floor on `lib/services`; the 401/403/5xx matrix for `_report` has tests.
- Lints: `flutter_lints ^4.0.0` with `analysis_options.yaml` (38 lines); analyze runs with `--no-fatal-infos`.

---

## Additional findings detail

### MOB-003 (Medium) Ingest key lifecycle (backend + app)
- Evidence: `ingest_key.go:97-136` accepts the key with no expiry, no `token_version` check, and sets claims to the **owner user id only**; `location_batch.go:187-196` and the single ingest verify only that `device.user_id == claims.UserID`. Result: a key issued for phone A authorizes reports for any device of the same user. `Logout` (`auth.go:219-231`) only bumps `token_version`; the device row and `ingest_key_hash` survive, so the key stays valid after logout. `clear()` removes the key locally but the server copy of the credential persists. Password change and "log out everywhere" do not revoke it (not confirmed for the change-password handler, needs verification).
- Scenario: a leaked key (see MOB-002) lets an attacker spoof a family member's position for months, including after the user logs out or changes password.
- Fix: bind key to device (compare `deviceID` from header to body `device_id`), null `ingest_key_hash` on logout/device delete/password change, optional expiry with rotation, rate limit and audit log on first use from new IP. Effort M. Acceptance: tests show (1) key for device A rejected for device B, (2) key rejected after logout, (3) key rotation header honored.

### MOB-005 (Medium) Prefs key collision
- `ServerConfig` persists the user's server URL under `wb_api_base_url` (`server_config.dart:15`); `BackgroundCredentialStore` uses the identical key (`background_credential_store.dart:22`) and `clear()` removes it (`:42`), called by `TokenStorage.clear()` on every logout/session expiry. After a logout and an app restart, `ServerConfig.load()` finds nothing and falls back to the dart-define, so a generic/self-hosted APK user must re-enter their server (forced redo of onboarding, and can't log in at all if the server step is hidden elsewhere). It also makes the verification list at `token_storage.dart:176-183` depend on the URL. needs verification of UX, but the collision is certain from the source.
- Fix: use distinct keys (`wb_server_url` vs `wb_bg_api_base_url`) with a one-time migration; do not clear the server URL on logout. Effort S. Acceptance: test that logout leaves `ServerConfig` URL intact and clears background credentials.

### MOB-012 / MOB-013 detail
- MOB-012: add `android:dataExtractionRules="@xml/data_extraction_rules"` and `android:fullBackupContent="false"` excluding all domains; on iOS exclude the prefs and any queue file from backup via `URLResourceKey.isExcludedFromBackupKey` or move secrets to Keychain `ThisDeviceOnly`. Effort S.
- MOB-013: use `$(APS_ENVIRONMENT)` build setting or separate entitlements for Debug/Release (`Runner-Release.entitlements` with `production`). Effort S. Acceptance: archived IPA's embedded entitlements show `production`.

## Checked and found fine (summary)
- Refresh token not in plaintext prefs; logout verified-clear path; ATS default; `allowBackup=false`; cleartext disabled in release; service `exported=false`; FGS type `location` + permission for API 34; no `badCertificate` bypass; https-only server/tile/ntfy URLs with tests; mock-location rejection in background and push paths; command expiry + replay ring; photo picker without READ_CONTACTS/media-wide permissions; PendingIntents use `FLAG_IMMUTABLE`; ingest key hashed server-side with constant-time compare; plugin license MIT with notice retained.
