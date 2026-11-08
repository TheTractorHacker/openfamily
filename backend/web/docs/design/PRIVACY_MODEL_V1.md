# Privacy model v1: is it still end-to-end?

An independent review of who can read what in Orbitly today, a plain answer to "is it still end-to-end encryption if the server is in the group", and the recommended v1.0 positioning, naming and defaults.

Status: review, 2026-11-08, branch `feat/privacy-model`, against main at v0.25.2 plus the token-refresh hotfix.
Companion: [PRIVACY_MODEL_BACKLOG.md](PRIVACY_MODEL_BACKLOG.md) (prioritised change requests). Background:
[E2EE.md](E2EE.md), [PRIVACY_PROCESSING.md](PRIVACY_PROCESSING.md), [E2EE_CHAT.md](E2EE_CHAT.md).
Everything marked **verified** was checked in the code named next to it; nothing was run against the production
server. Phone behaviour on real devices was not exercised.

## 1. The short answer for the owner

**Is it still end-to-end encryption with the server in the group?** For some data, yes; for some, no; and the app
currently says "yes" for all of it. Precisely:

* End-to-end encryption is a statement about **who holds the keys**, not about where the bytes travel. Data sealed
  under the phone key (`CK`) can only be opened by circle members' phones and the viewers they approved. The server
  never receives `CK` (database trigger `e2ee_wrap_guard`, phone check `checkWrapRecipient`, sidecar alarm exit 7:
  **verified**). That part is real end-to-end encryption and it did not get weaker.
* A member on the **server lane** seals their location under the server key (`SK`), which the server holds. For that
  member's location, trips, places, events and check-ins the server is one of the ends. Cryptographically that is
  no different from a Normal circle: the server reads it and keeps a plaintext copy in `locations`. Calling that member's
  data "end-to-end encrypted" is false; the honest term is "encrypted in transit, readable by your server".
* **Chat** in a Private circle is always under `CK` (CHECK constraint `e2ee_items_chat_phone_only`, **verified**), so chat
  stays end-to-end encrypted even for server-lane members. That is a genuine improvement over Normal circles.
* The server key is registered under the **platform admin's own account**, and server help only works in circles
  where that account is a live member (`e2ee_server_assist`, migration `000220_processing_lanes.up.sql` line 168,
  **verified**). So wherever the server helps, the person who runs the server is already in the circle and reads
  everyone, including "phone only" members, on their own phone. "Phone only" therefore protects against the
  **machine** (a stolen disk, a hosting company, a backup, a breach of the server software), not against the
  **person** who runs it. That is still worth a lot, but it must be said that way.

**Is there a point having the server as a member?** Yes, but less than it looks. The features that truly need a
reader that never sleeps are few (section 4). Most of what the server lane gives today (trips, driving reports,
weekly summary, history, admin map, Dawarich, Home Assistant) is either already computable on phones, or needs only
a non-reading server that stores ciphertext, or is an operator convenience. The server lane is the right answer for
families who **trust their own box** and want everything to "just work" with no battery cost; it is the wrong default
for a rented VPS.

**Are we going the right direction or backwards?** The *architecture* is going forward: two key lines, per-member
signed choice, `CK` never on the server, chat always phone-to-phone, transparency log. The *defaults and the words*
went backwards in v0.24 to v0.25: a circle that is mostly server-processed still shows "End-to-end encrypted", members
are switched to the server by a server-wide setting without a tap ("auto-apply"), and a few leaks undercut the
phone-only promise (section 3). Fix the words and those leaks before v1.0 and the model is defensible and
differentiating. Do not market "end-to-end encrypted" for a circle; market it for **people who keep data on their
phone** and for **chat in Private circles**.

## 2. What each party can learn (truthful matrix)

Legend: **Reads** = can read content; **Meta** = metadata only; **No** = nothing useful. "Server lane" = a member
of a Private circle whose own signed lane is `server` (including members auto-applied). "Phone lane" = a member
of a Private circle who keeps data on the phone. All "verified" items were checked in code.

### 2.1 Location, places, trips, events, check-ins

| Party | Normal circle | Private, server-lane member | Private, phone-lane member |
|---|---|---|---|
| Server operator (DB, files, process) | Reads everything, history 90 days, last position kept until account deletion | Reads everything the phone sends after the lane was signed: fixes, history, trips, driving, places they created, events, check-ins (`SK`), stored as plaintext in `locations`/`member_positions` | Meta (see 2.3). **But see leaks L1 and L2 below**: SOS/help/check-in coordinates and place-picker coordinates reach the server in plaintext |
| Platform admin in the admin web | Only with `ADMIN_LOCATION_ACCESS=true` (audited). The switch is a UI/API rule; anyone with DB access reads regardless | Same as Normal | Sees "keeps data on phone" flag and counts; no data |
| Another circle member | Reads everything the circle shares | Reads everything (holds `CK` and `SK`) | Reads everything (holds `CK`). Opting out never hides you from members |
| Member's approved web viewer / Dawarich bridge | n/a (server feeds Dawarich directly) | Bridge: `SK` only in circles with server help. Web viewer: `SK` and, after a warning, `CK` | Web viewer with `CK`: reads. Bridge in a circle **without** server help holds `CK` and exports every member to its owner's Dawarich |
| Network attacker (no TLS break) | Meta: IPs, timing, sizes | Same | Same |
| TLS-terminating proxy (Cloudflare tunnel, CDN, reverse proxy you do not run) | Reads everything, plus session tokens (can act as any user) | Reads plaintext? No: items are sealed. Sees tokens, SOS/check-in coordinates (L1), geocoder queries (L2), and can serve modified web-viewer JavaScript | Same as server-lane, except nothing under `SK` exists |
| Stolen DB dump / DB backup | Everything | Plaintext copies of server-lane data. `SK` ciphertext needs the server device key, which is **not** in the DB | Ciphertext + metadata |
| Stolen whole disk or VPS snapshot (incl. `.env` and volumes) | Everything | Everything above plus the server device key and `OPENFAMILY_DATA_KEY` (it sits in `.env` on the same disk), so also future `SK` items until the key is revoked; plus `JWT_SECRET` (can mint a session for any account) | Ciphertext + metadata; still cannot get `CK` |
| Lost or stolen phone, powered off / before first unlock | Session token in secure storage; nothing else readable | Same | Same; vault cannot be opened |
| Lost or stolen phone, unlocked once since boot, then locked | With app-level code execution or a forensic exploit: tokens, local trail | Same, plus the Keystore can be asked to open the vault (no `setUnlockedDeviceRequired` since 0.24.2) | Same; on-device history and parked fixes are plaintext in the app sandbox anyway |
| Lost phone that someone can unlock | Everything the owner sees | Same | Same |
| Apple (APNs) | Visible push text: place name and circle name by default ("A family member arrived at School", "New message in Family"); person names and chat text previews if the recipient turned names on or `VERBOSE_PUSH=true`; device token, timing, IP | Private circles: silent `e2ee_wake` with circle id only; no text | Same |
| Google | No FCM, no Google Play services push. Exception: a Wear OS watch receives a **plaintext** snapshot through the Google Play services Data Layer (names, positions, place names, addresses), including Private circles unless the user turned "Show Private circles on the watch" off | Same | Same |
| ntfy / UnifiedPush distributor (if configured) | Same text as APNs | Silent wake only | Silent wake only |
| Map tile hosts (OSM/Esri by default) | The area being viewed and the phone's IP | Same | Same |
| Geocoder (Photon/Nominatim/Census via the server) | Typed addresses and pin coordinates | Same (L2) | Same (L2): the server and the geocoder see the pin of a place being created |
| SMS contacts (Twilio) | SOS share URL with position | Position if the member is server-lane (`memberPlaintextOK`) | No position (withheld), name and alert only |

### 2.2 Chat

| Party | Normal circle | Private circle (any lane) |
|---|---|---|
| Server operator | Reads text, photos, edit history, read markers | Ciphertext only; sees sender device, minute, size bucket, attachment size, read cursor ids (`E2EE_CHAT.md` section 5, **verified** against `chat_phone_only` rules) |
| Apple push | "New message in <circle>"; sender name and first characters of the text if the recipient opted in to names | Silent wake only |
| Members | Read | Read |
| Messages written before the circle turned Private | n/a | Stay readable on the server until an admin deletes them |

### 2.3 Metadata the server always sees (all modes)

Accounts, names, emails, avatars, circle membership and roles; every device's platform, OS version, push token,
battery-optimisation state, location and notification permission state and background-service flag
(`000175_reliability`); last seen, "phone went silent"; client IP addresses (audit log keeps them); key registrations,
revocations and approvals (key log, kept after account deletion); for Private items: sender device, purpose (`fix`,
`event`, `checkin`, `history`, `chat`, `trip`, ...), key line (who is server/phone lane), minute of arrival, size bucket,
upload cadence. Concrete inferences a curious operator can make in a Private circle without any key:

* an `event` item = this person just arrived somewhere or left; a `checkin` item = an alert or check-in; a `trip`/`drive` item = a trip just ended;
* adaptive cadence = moving vs. still;
* **on a home server, a phone that connects from the home LAN or the home's public IP is at home.** This is the
  strongest leak for the most common deployment and is not mentioned anywhere today.

### 2.4 Leaks found that contradict the phone-only promise

* **L1, SOS/help/check-in/crash coordinates (verified).** `sos_screen.dart`, `help_alert_screen.dart`,
  `sharing_service.dart` (`checkIn`), `crash_countdown_screen.dart` and `watch_bridge.dart` put `lat`/`lon` in the
  plaintext request body even when every circle of the user is Private; the server then **drops** them
  (`alerts.go`, `positionWithheld`). A server that is honest stores nothing, but the coordinates reach the server
  process and any TLS-terminating proxy. `E2EE.md` says "the server ... cannot know the position". It can. The
  check-in **note** is also sent and stored in plaintext.
* **L2, place picker geocoding (verified).** Creating or moving a place in a Private circle calls `GET /geocode/reverse`
  with the pin's coordinates and `GET /geocode/search` with the typed address and the pin as `near`
  (`place_picker_screen.dart`, `geocoding_service.dart`; no Private-circle guard). The server and the public geocoder
  learn "Home" and "School" coordinates of phone-lane members. `E2EE.md` says "the server never learns an address".
* **L3, watch snapshot (verified, documented).** Plaintext on the phone-watch link via Google Play services. The design
  doc says Google's servers are not used for the transfer; the Data Layer can sync through Google's cloud node when
  the watch is not directly connected (Wi-Fi or LTE watches), which needs checking against current Google docs before
  that sentence is repeated.
* **L4, home IP = at home** (2.3).

## 3. Claim strings: TRUE / MISLEADING / FALSE

Corrected wording uses plain words. "Fixed here" = changed on this branch (small, tested); everything else is a
change request in the backlog.

### 3.1 App (Flutter)

| Where | Claim | Verdict | Corrected wording |
|---|---|---|---|
| `widgets/private_circle_widgets.dart` map badge (used in `location_tab_view.dart`) | "End-to-end encrypted" / semantics "The server cannot read locations in this circle" for every Private circle that is not legacy | **FALSE** when server help is on and any member is server-lane | "Private, server helps some" + semantics naming who the server can read. **Fixed here** (`serverAssist` flag). Per-member counts belong in the backlog item B1 |
| `location_tab_view.dart` circle switcher subtitle | " - End-to-end encrypted" | **FALSE** for the same circles; also wrong for legacy circles | " - Private, server helps some" / " - Server can read" (legacy). **Fixed here** |
| `circle_detail_screen.dart` toggle subtitle | "On: only members can read locations" | **FALSE** with server help on | "On: the server reads members who use it". **Fixed here** |
| `circle_detail_screen.dart` info | "Positions, history, places and events are end-to-end encrypted: only the members can read them." | **MISLEADING** | Adds "except the data of members who use server processing, which the server can read too". **Fixed here** |
| `circle_detail_screen.dart` turn-on dialog | "Chat messages are not end-to-end encrypted in this version." | **FALSE** (chat is E2EE since 000250) | "Chat in this circle is end-to-end encrypted too." **Fixed here** |
| same dialog | "The server stores and forwards ciphertext only and cannot read where anyone is." | **MISLEADING** on a home server (the next screen offers to add the server; auto-apply then signs members in) and because of L1/L2 | "... cannot read where anyone is, unless a member lets the server process their data." plus fix L1/L2 (B3, B4) |
| `privacy_policy_screen.dart` | "Locations are readable by the server; they are not end-to-end encrypted." | **FALSE** for Private phone-lane | Normal: readable; Private: E2EE except members who let the server process. **Fixed here** |
| `circle_create_screen.dart` "Private" tile | "Only phones can read locations; the server keeps nothing readable." | **MISLEADING** on home servers with auto-apply; FALSE given L1/L2 | "Only phones in the circle can read locations, unless a member lets the server help. On this server, members are switched to server help by default." (profile-dependent) |
| same, "Normal (recommended)" | "Your server keeps locations so maps, history and driving reports just work." | TRUE, but "recommended" is wrong on a cloud profile | Recommend by profile: Home: Normal or Private + server; Cloud: Private |
| `welcome_screen.dart` | "Private by design. Self-hosted. No ads. Your location stays in your circle, on your own server." | **MISLEADING** (members of someone else's server; tile hosts, geocoder, APNs; "your own server" may be a rented VPS) | "Self-hosted. No ads, no tracking. Your locations go to the server your family chose, not to us." |
| `widgets/server_prompts.dart` auto-apply notice | "Your circle uses the server so maps, history and driving reports work. Tap to keep your data on your phone." | **MISLEADING** by omission: does not say the server can now read the person's location | "Your phone now lets this server read your location, trips and driving data (the server's owner and its backups can too). Tap Keep on my phone to undo and delete it." |
| `processing_widgets.dart` `turnOnBody` | "Each member decides for themselves ... You cannot change another member's choice." | **MISLEADING** on a server with auto-apply (default on Home): members who never decided are switched on at next app open | Add, when `auto_apply` is on: "On this server, members who have not chosen are switched to the server automatically the next time they open the app. They are told and can undo it." |
| `processing_widgets.dart` `turnOffBody` | "Copies the server already holds are not deleted automatically" | **FALSE** in the other direction: policy off deletes every server pref, and the pref trigger purges copies (`e2ee_policy_turned_off` -> `e2ee_pref_server_lane_changed` -> `e2ee_purge_user_server_copies`) | "The server's readable copies of members' locations are deleted now. Trips already built, alerts already sent, exports and backups are not." |
| `processing_widgets.dart` chip | "Processed by server" | TRUE but soft | "Server can read" |
| same | "Phone only" | **MISLEADING**: the data is still uploaded (encrypted) and readable by every member and their viewers | "Only circle phones can read" (short: "Phones only") |
| `processing_screen.dart` status | "Server-assisted (N of M members)" / "Phones only: The server cannot read this circle." | TRUE (best label in the app; reuse it on the map) | keep |
| `join_circle_screen.dart` | "... nothing is shared with the server unless you confirm it." (assist on, no auto-apply) and the auto-apply text | TRUE for each branch, provided the branch matches the server's flag | keep; add operator name (B6) |
| `encryption_keys_screen.dart` | "Private circles are end-to-end encrypted: the keys are made on this phone and never leave it. The server only stores public keys and scrambled copies it cannot read." | **MISLEADING**: the server key `SK` is wrapped to the server; server-lane items are readable | "... The phone key never leaves members' phones. If you let the server help, it gets a separate server key for your data only." |
| `PrivateFeature.trips` etc. | "In a Private circle the server cannot read them." | MISLEADING for server-lane members; only shown when no lane info exists | "... unless the person lets the server process their data." |
| `trusted_server_screen.dart`, `trusted_server_prompt.dart` | "This is NOT end-to-end encryption against the server" (legacy) | TRUE | keep |

### 3.2 Admin web

| Where | Claim | Verdict | Corrected wording |
|---|---|---|---|
| `EncryptionKeysPage.tsx` | "The server can read data of members who allow it (anyone with access to this server or its backups can too). Members who keep data on their phone stay end-to-end encrypted" | TRUE (add L1/L2 caveat once fixed or not) | keep |
| `PrivateCirclesPage.tsx` line 97 | "End-to-end encrypted circles. The server holds only ciphertext" | **FALSE** for circles with server-lane members | "Private circles. The server holds ciphertext for members who keep data on their phone and readable copies for members who use server processing." |
| `PrivateCirclesPage.tsx` line 260 | viewer threat model (operator can modify the JS) | TRUE | keep |
| `IntegrationsCard.tsx` | "(end-to-end encrypted) circle never exposes positions unless it uses trusted-server mode" | **FALSE** since lanes: Home Assistant gets server-lane members (`haPositions` gate is `keeps`, i.e. not phone-lane) | "A Private circle exposes only members who let the server process their data." |
| `TrustedServerDefaultCard.tsx` | "People can still choose strict end-to-end instead." | TRUE (legacy) | keep |
| `lib/deploymentProfile.ts` cloud text | "The company that runs the machine could read what the server can read" | TRUE | keep; say the same for Home ("anyone with access to the box or its backups") |

### 3.3 Docs and public text

| Where | Claim | Verdict | Correction |
|---|---|---|---|
| `docs/user/privacy-modes.md` | "Nobody can choose for you" (bottom) vs. the auto-apply section | **contradictory** | "On a Home server your phone switches you to the server by default; you are told and can undo it." |
| `docs/user/privacy-modes.md` | "Private. Only phones can read locations; the server keeps nothing readable." | MISLEADING (same as app) | as 3.1 |
| `docs/user/privacy-modes.md` | "Chat is stored readable on the server" (section "Chat, sharing links and SOS") | **FALSE** for Private | "Chat is readable by the server in Normal circles and end-to-end encrypted in Private circles." |
| `docs/user/privacy-modes.md` Private | "Trips, driving reports and weekly summaries are calculated on the phone" | partly TRUE (trips/week wired; driving report screens still gated, PRIVACY_PROCESSING 19) | "Trips and weekly figures are calculated on the phone; the driving report is not available yet for phone-only members." |
| `docs/admin/deployment-profile.md` | "Every circle admin and member still chooses on their own phone. Nobody, including you, can consent for another person." and "Whatever is suggested, the person still taps for themselves." | **FALSE** with auto-apply (default on Home) | The section later says "This is your policy, not each person's consent"; lead with that |
| `docs/faq.md` | "Can the person who runs the server see where I am? ... In a Private circle it cannot, unless you choose Use the server" | **MISLEADING**: auto-apply; and the operator is a circle member wherever the server helps | "In a Private circle the server machine cannot, unless you (or, on a Home server, your phone by default) let it. The person who runs the server can still see you on their own phone if they are in your circle, like any member." |
| `docs/faq.md` | "Does server processing mean my data is sent to a company? No." | **MISLEADING** on a VPS | "Not to Orbitly. If your server is rented, the hosting company runs the machine." |
| `docs/design/E2EE.md` | "Chat ... NOT end-to-end encrypted yet", "No chat or media is decrypted (still plaintext)", "SOS ... the server cannot know the position", "Geocoding moves to the phone; the server never learns an address" | **FALSE** (chat stale; L1; L2) | update after B3/B4 |
| `docs/design/PRIVACY_PROCESSING.md` 10.2 vs 23 | "The admin default is a default shown to joiners, never an outcome" vs. auto-apply | **contradictory** (22.1 says "Never auto-consent") | add a superseded note to 10.2 and 22.1 |
| `docs/design/PRIVACY_PROCESSING.md` 22.3 | switching to normal "Plaintext rows the server already holds for server-lane members stay" | likely **FALSE**: the mode-change trigger deletes prefs and the pref trigger purges | verify with a DB test, then correct |
| `docs/design/WATCH_APPS.md` | "Google's servers are not used for the transfer" | **UNVERIFIED** | "The transfer is handled by Google Play services; Google documents cloud sync when devices are not directly connected." |
| `PRIVACY.md` | see the store/policy list in the backlog | several FALSE | backlog section "For store listings and privacy policy" |
| `site/index.html`, `site/privacy.html` | "Push payloads contain no coordinates. The app fetches the real alert content from your server" / "A configured platform administrator can also access locations" / "Location data is not end-to-end encrypted." | MISLEADING / MISLEADING / FALSE | backlog, same section |

## 4. What really needs a server that can read

The test for each feature: could a server that stores only ciphertext, plus the members' phones, deliver it?

| Feature | Needs the server to READ? | On-device or cryptographic alternative | True limit |
|---|---|---|---|
| Arrive/leave alerts | No. Already done on phones in Private circles (accuracy gate, debounce ported from `geofence_eval.go`) | OS geofences: iOS `CLCircularRegion` (20 regions per app), Android `GeofencingClient` needs Google Play services, which the app avoids, so the app's own location stream is the right engine; result sealed as an `event` item | Alerts only exist while the sender's phone runs. A dead phone cannot say it left; neither can a server that gets no fixes. iOS delivers the receiver's notification through a silent push that iOS may delay or drop (fix: B10, notification service extension) |
| "Expected at school by 8:30" (missed arrival) | No | Phone seals the rule; server keeps only a deadline and an opaque token; the phone uploads an opaque "arrived" ack (or the sealed event) before the deadline; if none, the server pushes "Check on Alex: no arrival yet". Server learns a time, not a place | The server learns that a rule with a deadline exists |
| Phone went silent / low battery / offline | No: metadata the server already sees | as today | none |
| Driving reports, crash detection, phone use | No: the sensors are on the phone; the score is arithmetic | Already the design (`drive` items); screens still gated for phone-only members | Battery not measured on devices; iPhone has no driving sensors yet; algorithm parity with the server needs shared vectors |
| Trips, weekly summary | No | Implemented as `trip`/`week` items for phone-only members | Late when the phone was off; place names only from the circle's own places, not reverse geocoding |
| History, heat maps | No | Sealed `history` chunks are kept by the server (ciphertext) for the person's retention window; phones decrypt and render. 90 days is about 130 000 points, fine for a phone | Rendering cost on old phones; new phone sees history only within the relay retention |
| Long-term storage beyond 90 days | No | Server stores ciphertext longer (retention is a setting, not a cryptographic limit) | Disk use; members who leave keep old keys |
| Multi-device continuity, new phone | No | Recovery phrase or cross-signing from the old phone; relay replay | Losing every phone and the phrase loses phone-only data. That is the real price of E2EE; the server lane hides it |
| SOS to people outside the circle (SMS) | Yes, today | The phone sends the SMS itself (already offered offline), or the share link carries a decryption key in the URL **fragment** (`#k=...`, never sent to the server) and the browser decrypts the sealed position | The SMS contact's phone or browser must open the link; Twilio-sent SMS from the server cannot contain a position the server does not have |
| Live-share links | Yes, today | Same fragment-key link | A link is a bearer secret; whoever gets it reads |
| "Request location" | No | Content-free wake push; the target phone seals a fresh fix | iOS silent push limits |
| Admin map for the operator | Yes, by definition | The operator, if a member, uses the web viewer | none: that is the point |
| Home Assistant, Dawarich | Yes (they want plaintext) | Owner-run bridge off the server host (exists for Dawarich) | The bridge host reads what it is given |
| Reverse geocoding (addresses for stops) | Yes for whoever geocodes | Offline geocoding data on the phone (large), or only the circle's own place names | Real limit for pretty addresses |
| Alerts while EVERY phone is off | Nobody can | n/a | Physics, not crypto |

Conclusion: **nothing on the family-safety list strictly requires the server to read.** What requires it is (1)
people outside the circle (SMS with position, public links) unless fragment-key links are built, (2) the operator's
own admin view and integrations, (3) zero-battery-cost convenience on the phones, and (4) not having to manage a
recovery phrase. The honest selling point of the server lane is (3) and (4), not safety.

## 5. Model comparison

| | Life360-style provider | Self-hosted trusted server (Orbitly Normal) | E2EE with the server as an optional member (Orbitly Private + lanes, today) | Fully E2EE (Orbitly Private, server help off) |
|---|---|---|---|---|
| Who can read location | The company, its partners, data brokers (Life360 sold location data until 2022), law enforcement requests | Your server's operator, the machine's host, backups | Phone-lane members: only circle members. Server-lane members: as Normal | Only circle members and their approved viewers |
| Chat | Provider reads | Operator reads | E2EE | E2EE |
| Features | All, polished | All | All for server-lane members; phone-computed for others (drive report pending) | Phone-computed; no SMS position, no public links, no admin map |
| Battery | Low | Low | Low for server lane, higher for phone lane (unmeasured) | Higher (unmeasured) |
| Lost every phone | Nothing lost | Nothing lost | Server-lane: history survives; phone-lane: lost without phrase | Lost without phrase |
| Metadata | Everything | Everything | Membership, timing, IP, purposes | Same |
| Main risk | Business model | One box, its admin and backups | Mislabelling: people think they are E2EE when they are on the server lane | Usability (phrase, iOS push, battery) |

The third column is a legitimate and rare design (Signal-style keys, per-person consent, the server as a visible,
revocable device). It is only better than the second column if the labels make the per-person reality obvious.

## 6. Recommended v1.0 positioning and naming

1. **Name the modes by who can read, per person, not per circle.**
   * Circle modes: **Standard** ("your server can read locations and chat") and **Private** ("locations are locked
     on phones; chat is always end-to-end encrypted").
   * Inside a Private circle each person is **"Server can read"** or **"Only circle phones can read"**. The circle header
     shows the honest mix: "Private: 2 of 3 keep data on their phone. The server can read Blake's location."
   * Keep "End-to-end encrypted" only for things where it is true for everyone: chat in Private circles, and a Private
     circle where nobody is on the server lane.
2. **Per-person "Who can read my data" screen** listing: circle members (always), the server (yes/no, since when, how:
   your choice or auto), approved viewers and bridges by owner, Apple push (what text), the watch, Home Assistant,
   Dawarich, and the server operator's name.
3. **Auto-apply is a policy, so present it as one.** It must be bound to a signed decision of the circle admin (not an
   unsigned server-wide flag), shown before joining, and announced after it happens with wording that says "the
   server can now read your location". Never call an auto-applied member's state "your choice".
4. **Store listing claim set** (backlog section "For store listings and privacy policy" has the exact lines): allowed
   "Optional Private circles: locations and chat are end-to-end encrypted between members' phones. Each person can let
   the family's own server process their data instead." Not allowed: "end-to-end encrypted location sharing" without
   the qualifier, "the server cannot read your location", "no one but your family can see where you are".

## 7. Recommended defaults for new circles

| Server | Recommended default | Why |
|---|---|---|
| **Home** (box the family owns, full-disk encryption on) | New circle: **Standard** is acceptable and simplest; or **Private with server help, auto-apply off**, with the member asked once ("Use the server (recommended) / Keep on my phone"). If auto-apply stays, it must be a signed circle-admin choice and the header must show per-member reality | The operator is family and is in the circle anyway; the threat is a stolen box or backup, which full-disk encryption and encrypted backups address |
| **Cloud / VPS / unknown** | **Private, server help off.** "Normal (recommended)" must not be the recommendation | The machine's owner is a company; Normal hands it everything; the server lane hands it everyone who taps "recommended" |
| Anyone with a child account | Pairing-time choice (already) and the parent's view of what the server reads | consent by proxy must be visible |

The create-circle screen should pick the recommended tile from the deployment profile (`profile_effective` is
already sent to apps in `GET /e2ee/server-device`).

## 8. Top 10 ways a normal user could be misled or the model defeated (red team)

Read-only reasoning; no attacks were run. Ranked by plausibility times impact.

| # | Scenario | Cheapest mitigation |
|---|---|---|
| 1 | A teen on a home server sees a lock and "End-to-end encrypted" on the map and believes the parent who runs the server cannot see the history. Auto-apply put them on the server lane at first app open; the notice did not say "server can read" | Per-member header label (fixed here for the badge; B1 for counts and names); notice wording (B2) |
| 2 | A cloud-profile operator flips `member_defaults.auto_apply` on (one API call, unsigned, server-wide); every undecided member in every circle with server help on is signed onto the server lane at next app open, with no fingerprint comparison | Bind auto-apply to a signed field in the circle admin's `processing_policy` (or to `default_for_new = server` plus a new bit), never to the server flag; show "auto" vs "chosen" in the key log (B2) |
| 3 | A phone-lane member sends SOS; the coordinates go to the server in plaintext (L1). A compromised server, a malicious reverse proxy, or a debug log captures them | App omits `lat`/`lon` when the alert's circle is Private and the member is phone-lane (`uplinkModeFor` already knows); server test that rejects or never sees coordinates (B3) |
| 4 | A phone-lane member creates "Home" with the pin; the server and Photon see the exact coordinates (L2) | Disable reverse geocoding and `near` in Private circles for phone-lane members, offer typed search with an explicit "this sends the address to your server and the geocoder" notice (B4) |
| 5 | Operator runs a Cloudflare Tunnel (common for home servers). Cloudflare terminates TLS: reads Normal circles, chat, session tokens, SOS coordinates, and can inject JavaScript into the web viewer | Document it in the deployment profile and the privacy page; prefer TLS passthrough; warn in the admin system check when `TLS_BEHIND_PROXY` is set with a non-local proxy (B12) |
| 6 | The operator is in the circle (required for server help) and reads phone-only members on their own phone; members think "phone only" means "the server owner cannot see me" | Say it: "Phones only means the server machine cannot read you. Everyone in the circle can, including the server's owner if they are a member." Show the operator's name (B6) |
| 7 | A member approves a browser viewer; the operator (who serves the JavaScript) modifies the bundle and exfiltrates `CK` | Already documented; add a visible "viewers can be read by whoever runs the website" line on the members' processing screen next to "X has a web viewer"; consider a separately hosted static viewer later (B13) |
| 8 | A Dawarich bridge in a circle without server help holds `CK` and exports every member, including phone-only ones, to its owner's Dawarich; other members only see it if they look at the admin view | Show "Alex's Dawarich bridge can read everyone in this circle" to every member on the circle's processing screen (B11) |
| 9 | A member loses their phone and revokes its key from the new phone; the revoke deletes the prefs it signed and purges their server copies (`e2ee_processing_key_revoked` -> purge): their server-side history and trips source data are gone. Or they lose every phone and the phrase: phone-only data is gone | Warn before revoking ("this also deletes what the server holds of you in N circles"); or re-sign the lane from the new phone before the revoke; recovery phrase nudges (B9) |
| 10 | Apple push: a Normal-circle member turns on names in notifications; APNs receives "Mom: I'm at the clinic" and "Mom arrived at Clinic" as visible text; the user believes "self-hosted" means nothing goes to Apple | Use APNs `mutable-content` + Notification Service Extension: send an encrypted or content-free payload and render text on the phone, for every circle (B10). Until then, say exactly what Apple sees in the notification settings |

Also plausible but lower: the home-IP inference (L4), the plaintext watch snapshot (L3), a reset key approved by a
careless admin, and a split-view key log (documented in E2EE.md).

## 9. Unlock-independent key wrap (phones)

Since 0.24.2 the Keystore wrapping key is usable while the phone is locked (after the first unlock since boot), so
background sealing works. This is the right trade-off for a location app: without it every locked-phone fix waited
for the next unlock, which defeated the product. What it costs: an attacker with code execution as the app, or a
forensic tool on a seized phone in the "after first unlock" state, can open the vault. What it does not cost: a
powered-off or never-unlocked phone, disk images and backups still yield nothing. The on-device trail, queue and
results were never protected by the Keystore anyway (app sandbox only). Keep it; state it in the "Who can read my
data" screen under "If your phone is stolen".

## 10. The built-in server device key and OPENFAMILY_DATA_KEY

What the key on the server's disk (`/data/server-device`, volume `server_device`) does: it lets the server open
`SK` items of server-lane members, and it is how phones can **prove** which server they consented to (the
fingerprint in every signed pref). It is an access-control and consent mechanism more than a confidentiality one:
for server-lane members the plaintext already sits in `locations`, so the key protects little at rest.

What `OPENFAMILY_DATA_KEY` adds: the key file (and the SMS token, Home Assistant secret) are sealed with it, so a copy
of the **volume alone**, or of a DB dump, does not yield the server key. It does **not** help when the attacker has
the whole disk or a VPS snapshot, because `scripts/setup.sh` writes it into `.env` next to `docker-compose.yml`. On a
VPS the provider can snapshot both. Honest wording: "protects copies of the data volume and database backups; does
not protect against anyone who has the whole machine". Real improvement: `OPENFAMILY_DATA_KEY_FILE` on separate
storage, systemd credentials or a TPM, or typed at start (B8).

## 11. What was verified and what was not

Verified by reading code: key-line rules (`e2ee_wrap_guard`, `checkWrapRecipient`), chat phone-line only, server
assist requires the key owner to be a live member, ingest and reader gates (PRIVACY_PROCESSING 20.1), purge
triggers, auto-apply conditions (`LanesService.autoApplyIfDue`), push copy (`chatPushCopy`, `buildNotification`,
`recipients`), alert coordinate handling (`alerts.go`, app senders), geocoding call sites, embedded device storage,
admin and user-facing strings listed above.
Not verified: behaviour on real phones, iOS (nothing in this area has run on an iPhone), the Wear OS Data Layer
transport, a live Cloudflare deployment, the 22.3 purge behaviour on switching to Normal (needs a DB test), battery.
