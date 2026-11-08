# Privacy model backlog (v1.0 and after)

Prioritised change requests from the privacy-model review, with files, risk, size and whether each is a MUST for the v1.0 store submission.

Source: [PRIVACY_MODEL_V1.md](PRIVACY_MODEL_V1.md) (matrix, claim audit, red team). Size: S (under a day), M (1 to 3
days), L (a week or more). Risk = risk of the change itself. "MUST" = must land before submitting v1.0 to the App
Store and Google Play, because a store reviewer, a journalist or a family member could otherwise show that a
privacy claim is false.

## Already done on this branch

* Map badge and circle switcher no longer say "End-to-end encrypted" for a Private circle with server help on
  ("Private, server helps some" / "Private + server"; legacy circles "Server can read"). `PrivateCircleBadge.serverAssist`,
  `location_tab_view.dart`, test in `app/test/widgets/private_circle_widgets_test.dart`.
* Circle settings subtitle and info no longer say "only members can read" when server help is on.
* The turn-on dialog no longer says chat is not end-to-end encrypted.
* The in-app privacy policy no longer says locations are never end-to-end encrypted.

## MUST for v1.0

| ID | Change | Files | Risk | Size |
|---|---|---|---|---|
| B1 | **Per-member truth in the circle header.** Replace the remaining circle-level claims with the real state: "Private: 2 of 3 keep data on their phone. The server can read Blake." Use the verified lanes (`LanesService`/`ProcessingSnapshot`), not the unsigned `server_assist` flag, for the names; the badge fixed here is the minimum. Also the member row: "Server can read" / "Only circle phones can read" | `widgets/private_circle_widgets.dart`, `location_tab_view.dart`, `processing_widgets.dart` (`LaneChip` labels), `encryption_keys_screen.dart` | Low | M |
| B2 | **Auto-apply is consent-by-default: make it honest and bound to a signed decision.** (a) Notice text must say the server can now read the person's location, trips and driving data, and who that includes (server owner, backups); show it as a blocking sheet the first time, not only a dismissible card. (b) Gate auto-apply on a signed circle-admin field (new bit in `processing_policy`, or `default_for_new = server` plus the existing server flag), not only on the unsigned server-wide `member_defaults.auto_apply`. (c) Mark auto-applied prefs as "auto" in the key log view. (d) Admin turn-on text says members are switched automatically when the flag is on. (e) Fix contradictions in `docs/admin/deployment-profile.md`, `docs/user/privacy-modes.md`, `PRIVACY_PROCESSING.md` 10.2 and 22.1 | `services/e2ee/lanes_service.dart` (`autoApplyIfDue`), `widgets/server_prompts.dart`, `widgets/processing_widgets.dart`, `backend/internal/e2ee/lanes.go` if the policy statement changes (frozen vectors: prefer a new optional field outside the signed bytes only if signed elsewhere), docs | Medium (wire format if (b) changes the statement) | M (text) / L (signed bit) |
| B3 | **No plaintext SOS/help/check-in/crash coordinates for phone-lane members.** Omit `lat`/`lon` (and the check-in `note`, or seal it) in the request body when every circle the alert goes to is Private and this member is phone-lane; the sealed `checkin` item already carries them. Add a regression test that the queued body has no coordinates in that state. Update `E2EE.md` ("the server cannot know the position") only after the fix | `screens/sos_screen.dart`, `screens/help_alert_screen.dart`, `screens/crash_countdown_screen.dart`, `services/sharing_service.dart`, `services/watch/watch_bridge.dart`, `services/e2ee/private_runtime.dart` (helper), tests | Medium (SOS path: keep the alert itself unconditional) | S-M |
| B4 | **No reverse geocoding of Private-circle places for phone-lane members.** In the place picker for a Private circle: no automatic `/geocode/reverse`, no `near` parameter; typed search only after a one-line notice ("sends the address to your server and to the address service") | `screens/place_picker_screen.dart`, `services/address_suggester.dart`, `services/geocoding_service.dart` | Low | S |
| B5 | **Fix every FALSE string listed in PRIVACY_MODEL_V1 section 3** not fixed here: `circle_create_screen.dart` Private tile and profile-dependent "recommended"; `welcome_screen.dart` "Private by design"; `encryption_keys_screen.dart` info; `PrivateFeature` explanations; `processing_widgets.dart` `turnOffBody` (copies ARE purged on policy off); `PrivateCirclesPage.tsx` line 97; `IntegrationsCard.tsx` (Home Assistant sees server-lane members); `docs/faq.md`; `docs/user/privacy-modes.md` (chat line, "Nobody can choose for you"); stale chat lines in `E2EE.md`. Web changes need `npm run build` and the committed `backend/web/dist` | listed | Low | S-M |
| B6 | **Show who runs the server.** The server key is registered under the platform admin's account and server help works only where that account is a member (`e2ee_server_assist`). Show "This server is run by <name>. <name> is in this circle." in the add-server sheet, join screen and the "Who can read my data" screen | `services/e2ee/add_server_flow.dart`, `screens/join_circle_screen.dart`, `screens/processing_screen.dart`; server: expose owner display name in `GET /e2ee/server-device` | Low | S |
| B7 | **Store and privacy texts consistent with reality** (section below) | `PRIVACY.md`, `site/*.html`, `app/ios/Runner/PrivacyInfo.xcprivacy`, Play Data safety, listing drafts | Low | S |

## SHOULD for v1.0 (ship if time allows, otherwise first point release)

| ID | Change | Files | Risk | Size |
|---|---|---|---|---|
| B8 | **`OPENFAMILY_DATA_KEY` honesty and option.** Docs and admin card: protects volume copies and DB backups, not a whole-disk/VPS snapshot because it sits in `.env`. Offer `OPENFAMILY_DATA_KEY_FILE` on separate storage or systemd credentials; admin system check warns when the key is in the same `.env` on a cloud profile | `docs/server-setup.md`, `docs/admin/deployment-profile.md`, `backend/internal/handlers/admin_system.go` | Low | S |
| B9 | **Lost phone does not silently delete server history.** Revoking the phone key that signed a server pref purges that member's server copies (`e2ee_processing_key_revoked`). Warn before the revoke, or let the new phone re-sign the lane first and only then revoke. Also a recovery-phrase reminder for phone-lane members ("without it, a lost phone loses your history") | `screens/encryption_keys_screen.dart` (revoke), `services/e2ee/lanes_service.dart`, migration only if the purge rule changes (use the diag/chat/docs range rules) | Medium | M |
| B10 | **Push content through Apple.** Use APNs `mutable-content` with a Notification Service Extension: the server sends a content-free or sealed payload and the phone renders "Mom arrived at School" locally, for Normal circles too. Until then the notification-names setting must say "Apple delivers this text" | `app/ios/` (new NSE target), `backend/internal/push/push.go`, `handlers/chat.go`, `handlers/geofence_eval.go`, `handlers/alert_delivery.go` | Medium (iOS target, unverifiable without a Mac) | L |
| B11 | **Every reader visible to every member.** On the circle's processing screen list for all members: the server (who runs it), each web viewer and bridge and whose it is, and whether it holds the phone key ("Alex's Dawarich bridge can read everyone in this circle") | `screens/processing_screen.dart`, `GET .../processing` already has devices | Low | S |
| B12 | **TLS-terminating proxies.** Document that Cloudflare Tunnel or any CDN in front of the server reads Normal circles, session tokens and (until B3) SOS coordinates, and can alter the web viewer. Admin system check info line when `TLS_BEHIND_PROXY=true` | `docs/admin/https-and-domain.md`, `docs/custom-domain.md`, `admin_system.go` | Low | S |
| B13 | **"Who can read my data" screen** per person: members, server (yes/no, since, chosen or auto), viewers/bridges, Apple push text, watch, Home Assistant, Dawarich, "if your phone is stolen" (unlock-independent key wrap explained). Entry from Settings > Privacy and from the circle header | new `screens/who_can_read_screen.dart`, reuse `ProcessingController` | Low | M |
| B14 | **Watch wording.** Replace "Google's servers are not used for the transfer" with what Google documents for the Data Layer, and default "Show Private circles on the watch" to off for phone-lane members, or ask once | `docs/design/WATCH_APPS.md`, `docs/user/watch.md`, watch settings | Low | S |
| B15 | **Home-IP inference.** Say in the Private-circle explainer that on a home server, connecting from home tells the server you are home. Optional mitigation: none cheap; documenting is the fix | `docs/user/privacy-modes.md`, `processing_widgets.dart` `metadata` | Low | S |
| B16 | **DB test for switching a circle to Normal**: confirm whether server-lane copies are purged (the mode-change trigger deletes prefs, which fires the purge) and correct `PRIVACY_PROCESSING.md` 22.3 | `backend/internal/handlers/e2ee_processing_db_test.go` | Low | S |

## LATER (v1.x and v2)

| ID | Change | Notes | Size |
|---|---|---|---|
| B20 | **Encrypted chat in every circle.** Design: a Standard circle gets a circle key `CK` exactly like a Private circle, used for the `chat` purpose only; locations keep flowing in plaintext. Cost: every member needs a device key (today keys are registered only for Private circles), key epochs on join/leave, the publisher-availability wait for new members, the recovery phrase story for chat history (relay keeps 30 days, so a lost phone without phrase loses only up to 30 days), old apps cannot read chat (the existing `chat_encrypted` 409 path). Simpler equivalent: make every new circle Private with everyone on the server lane by default (section B21) | L |
| B21 | **One model instead of three.** Every circle is Private; each person is "Server can read" or "Only circle phones can read"; chat always end-to-end. Standard becomes "everyone on the server lane". Removes the Normal/Private/legacy split and the mislabelling class of bugs. Needs: server places/geofences, bubbles and Home Assistant events for server-lane members inside lanes circles (today blocked circle-wide by `e2ee_plaintext_blocked`), a migration path for existing Normal circles, and the key UX for everyone | L |
| B22 | **Fragment-key links** for SOS share links and live-share: the browser gets the circle-independent per-link key in `#k=` and decrypts a sealed position. Brings SMS-contact positions and public links to phone-lane members without the server reading | M |
| B23 | **Server-blind missed-arrival alerts**: deadline-only rule on the server, opaque ack from the phone | M |
| B24 | **Signed ingest requests** (device key instead of a bearer token) and an off-host default for cloud profiles | M |
| B25 | Separately hosted, hash-pinned web viewer (reduces the operator-can-backdoor-the-viewer risk) | M |

## For store listings and privacy policy

For the store-readiness agent (works in `wt/storedemo`). Do not copy text from the old drafts without checking it
against this list.

### Claims allowed in store listings

* "Self-hosted: your family's locations go to a server you or your family chose, not to us."
* "No ads, no analytics, no tracking SDKs."
* "Optional Private circles: locations and chat are end-to-end encrypted between members' phones. Each person can
  let the family's own server process their location instead, which turns on server reports for them."
* "In Private circles, chat is always end-to-end encrypted."
* "Encrypted in transit (HTTPS only)."

### Claims NOT allowed

* "End-to-end encrypted location sharing" without "optional" and "Private circles".
* "The server cannot read your location" / "Only your family can see where you are" (false for Normal circles and
  for server-lane members; the server's operator is a person too).
* "Zero-knowledge", "military-grade", "nobody can see your data".
* "Push notifications contain no personal data" (place names and circle names go through Apple; with names turned on,
  person names and chat previews).
* Any battery claim about phone-only processing (unmeasured).

### Required corrections in existing texts

| Text | Current | Correction |
|---|---|---|
| `PRIVACY.md` "Private circles" | "Chat messages are not end-to-end encrypted yet." | Chat in Private circles is end-to-end encrypted (since 000250); Normal-circle chat is readable by the server |
| `PRIVACY.md` "Private circles" | "Trips, driving reports and the weekly summary are not available for Private circles" | Available for members who let the server process their data; trips and weekly figures computed on the phone for others; driving report pending for phone-only members |
| `PRIVACY.md` "Optional: trusted server member" | describes the legacy all-members mode as current | Replace with per-person server processing; on a Home server members are switched to the server by default (auto-apply) and told; mention the server key lives on the server's disk |
| `PRIVACY.md` "What leaves your server" HA bullet | "never anything about a Private circle's positions unless that circle is in trusted-server mode" | "... except members of a Private circle who let the server process their data" |
| `PRIVACY.md` "Who can see location" | "The platform admin of that server" | "The server's operator (anyone with access to the machine or its backups) in Normal circles and for members who let the server process their data; the admin web map additionally needs `ADMIN_LOCATION_ACCESS`" |
| `PRIVACY.md` "iOS push" | "Payloads do not include coordinates." | Add: "They include place names and circle names, and person names and chat previews if names are turned on in notification settings. Private circles send a content-free wake-up." |
| `PRIVACY.md` / policy | missing | Metadata in Private circles (membership, timing, IP, device diagnostics, item types); Wear OS watch receives a plaintext snapshot via Google Play services; check-in notes are stored readable; SOS coordinates (until B3) |
| `app/lib/screens/privacy_policy_screen.dart` | fixed here (Normal vs Private) | keep in sync with `PRIVACY.md` |
| `site/privacy.html` | "Location data is not end-to-end encrypted." | "In Normal circles the server can read locations. Optional Private circles encrypt locations and chat end-to-end between phones, except for members who let the server process their data." |
| `site/index.html` "iOS push" | "Push payloads contain no coordinates. The app fetches the real alert content from your server over TLS." | Second sentence is false today (the alert text is in the push). Use the `PRIVACY.md` wording above |
| `site/index.html` FAQ | "A configured platform administrator can also access locations through the web panel." | "Whoever runs the server can read locations of Normal circles; the admin web map is off by default and every look is logged." |
| `docs/design/IOS_RELEASE.md` App Review text | "Data goes only to the family's self-hosted server." | Add "and, for notifications, Apple's push service". |
| `docs/google-play-release.md` Data safety | "Location can be viewed by same-family members and the server operator." | Keep; add "except Private-circle members who keep data on their phone". Declare: precise location, name, email, user IDs, device IDs, photos (avatar, chat), messages (chat), other user content (places, notes), app diagnostics (OS version, permission states). Encrypted in transit: yes. Deletion: in app plus the public URL |

### Apple App Privacy and Google Data safety answers (consistent with the code)

Conservative answers for an app that sends data to a server chosen by the user; the publisher should confirm with
current Apple and Google definitions and with whether the publisher itself runs a server users can sign up on (the
demo server: then it collects for those users).

| Data type | Collected | Linked to the user | Tracking | Purpose |
|---|---|---|---|---|
| Precise location | Yes (Normal circles and server-lane members readable; phone-lane members encrypted, still transmitted) | Yes | No | App functionality |
| Name, email | Yes | Yes | No | App functionality, account |
| Phone number | Optional (profile, emergency contacts) | Yes | No | App functionality |
| Photos | Optional (avatar, chat photos) | Yes | No | App functionality |
| Messages (in-app chat) | Yes (Normal circles readable; Private end-to-end encrypted) | Yes | No | App functionality |
| Other user content (places, check-in notes) | Yes | Yes | No | App functionality |
| User ID, device ID, push token | Yes | Yes | No | App functionality |
| Diagnostics (OS version, battery-optimisation and permission states, push outcome) | Yes | Yes | No | App functionality |
| Crash data, analytics, advertising data | No | | | |

`app/ios/Runner/PrivacyInfo.xcprivacy` must list the same types. Today it declares precise and coarse location,
contacts, device ID, email, name, other user content, phone number, photos or videos and user ID; it is missing
**Emails or text messages / in-app messages** (`NSPrivacyCollectedDataTypeEmailsOrTextMessages`, for chat) and
**Other diagnostic data** (`NSPrivacyCollectedDataTypeOtherDiagnosticData`, for the device diagnostics in
`000175_reliability`). Google Play: "Data is encrypted in transit": yes. Do not tick
"data can be deleted" without the in-app delete and the public URL both working.
