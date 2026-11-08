# Changelog

What changed in each Orbitly release (published as OpenFamily before the rename), in plain words. The server shows the
section for the version it runs on the admin **Documents** page and on
**Settings, App versions**. Older entries are in the git history
(`git log v0.16.0..`); this file starts at v0.17.

Each release says which app versions it works with. The server keeps working
for the **last 5 minor versions** of the app (see
[API compatibility](api-compat.md)), so you can update the server first and
the phones afterwards.

## Unreleased

Nothing yet. The owner moves these notes under a version heading when a
release is tagged.

## v0.26.0 (2026-11-08)

Works with app versions 0.22 to 0.26. The server update is safe to apply first.

- **The Driving dashboard is back.** The full dashboard (top speed, drives, distance, event
  chips with trends, week and month views, daily chart, driver cards, recent drives with a map)
  works for Normal and Private circles. In a Private circle, members on the server and phone-only
  members appear in the same totals. Offline it shows the last saved report with its age.
- **Real names.** The people list, map, chat, alerts, weekly summary and crash reports show the
  person's name, with "(you)" for yourself, instead of a bare "You".
- **The check-in pop-up stays dismissed** once you acknowledge it, also after restarting the app.
- **Clear "please sign in again".** When a login really expired the app now says so, keeps queued
  SOS, check-ins and messages, and no longer reports "can't reach the server". The app's screen and
  background service take turns refreshing the login. Parked positions are sent whenever the phone
  holds the circle key.
- **Smooth on foldable phones.** Folding or unfolding no longer restarts the map and tabs. The
  layout switches between a bottom bar and a side panel while keeping the map where it was.
- **iPhone battery.** Background location now adapts: best accuracy while driving, saving modes
  while walking, and a cell-tower-only mode with a 150 m wake boundary while resting.
- **Watch smoothness and battery** (see below), plus faster list drawing and a startup profile on
  Wear OS.
- **Privacy wording fixes** in the app: the badge now says what the server can really read.
- Store kit, legal pages (`/privacy`, `/terms`), faster build pipeline, and the performance and
  privacy design documents are in the repository.

- **Fewer surprise sign-outs.** One phone has several parts that refresh the sign-in together
  (the screen, the background location service, a retry). The server treated the third as token
  theft and signed the person out, which showed up as "Couldn't reach the server". For 10 seconds
  after a refresh token is used, repeated refreshes now get the same new token. After that, and
  if the new token was already used, the strict theft rules still apply.
- **Watches: much lighter on both batteries.** The phone used to send the watch a new update
  nearly every 5 seconds whenever anyone's position changed, each one waking the watch at once.
  Now it sends every few seconds only while the Orbitly app is open on the watch; otherwise
  only real changes (someone moved more than 100 m, arrived or left, a battery step), at most
  every 2 minutes, plus a check every 10 minutes. Alerts, answers to watch buttons, new
  messages and sharing changes still arrive within seconds. In a test hour with someone
  driving: 31 updates instead of 720. "Left Work 25 min ago" is now counted on the watch. The
  phone also stopped asking the server for alerts and the sharing pause every minute while a
  watch is connected, and notices an Orbitly watch connecting or leaving right away. Wear OS
  tile and complication redraw only when what they show changed. Needs the matching watch app
  (older watch apps keep working, with the old timing for connect and disconnect).

## v0.25.2 (2026-11-08)

- Build fixes only: the Android app did not compile in v0.25.0 and v0.25.1 (a key-storage
  call that does not exist and a deprecated watch listener setting). Same server as
  v0.25.0. The phone APK, AAB, Wear OS APK and iPhone file are attached to this release.
  The phone no longer wakes when a watch merely connects while the app is closed;
  it still wakes for watch commands.

## v0.25.1 (2026-11-08)

- Build fixes only: the v0.25.0 Android and Wear OS release files were not produced
  (code-style checks and a signing-key path in the build scripts). Same app and
  server as v0.25.0; the files are attached to this release.

## v0.25.0 (2026-11-08)

Works with app versions 0.21 to 0.25. The phone and watch apps are the big
change; the server update is safe to apply first.

- **Admin site overhaul.** A grouped, collapsible menu with page and settings
  search, a Settings page with its own section menu and (i) help, new
  administrator settings (sign-in session lifetime, idle timeout and sessions per
  person, and the default for members), a Builds page that lists the Android
  APK and the iPhone IPA (plus the Wear OS watch APK), a System health checklist
  with a fix hint for every row, a **Server processing** panel on the Dashboard
  and Private circles pages, and Fleet health that shows one row per phone with
  the real app version and 'what to do' hints.
- **Sessions.** Signing in again from the same phone replaces its old session
  instead of adding another, idle sessions expire after 14 days, there is a limit
  per person, and administrators can sign out sessions in bulk.
- **Phones on low memory.** The app picks a profile by the phone's RAM (under 4 GB
  lite, 4 to under 6 GB standard, 6 GB and up full), trims caches when Android asks
  for memory, and the release now ships a combined APK plus per-CPU APKs.

- **Faster on mobile data.** The server now compresses its answers, the app
  reuses its connection to the server instead of reconnecting for every
  request, and unchanged lists come back as a tiny "not modified" answer.
- **Smaller updates.** The people list and saved places can be fetched as
  "only what changed", with a compact view for the map and watch. One start-up
  request (`/app/bootstrap`) replaces five.
- **Lighter history.** A day's trail can be thinned on the server to as many
  points as the map can draw; the audit log can be paged.
- **Steadier connection.** Reads retry a couple of times with a short random
  pause when the network blips; writes are never repeated automatically.
- **Optional HTTP QUERY method** for multi-window history reads, off by default
  (`QUERY_METHOD=1`); the app falls back to POST by itself. Details and the
  Cloudflare check are in [API wire efficiency](developers/api-efficiency.md).
- Database: places gain an `updated_at` (migration 000360).

- **Orbitly keeps working when the server is down.** The app remembers the last people, positions
  (with their real age), places, circles, chat and notifications and shows them at once, with a
  small bar: "Server unreachable. Showing last known. Will sync when it is back." (and Try again).
  Chat messages, check-ins, Help alerts and SOS written meanwhile are saved on the phone and sent in
  order, once, when the server is back. An SOS that cannot be delivered says "SOS not sent yet", keeps
  trying and offers to text your emergency contacts from your own messages app. New movement of other
  people still needs a server. See "When the server is down".
- Fixes: a long outage no longer discards the queued location points or queued Private circle
  messages and check-ins; the app opens within 4 seconds on a dead network and never signs you out
  because of a network error; Diagnostics counts every waiting update.
- Server: SOS, Help alerts and check-ins accept an optional `client_id` so a replay after a lost
  answer is stored once (database migration 340).

- **Private circles keep sending when the phone is locked.** The key that
  protects your keys on the phone no longer needs the screen to be unlocked
  (it is still stored in the phone's security chip and can not be copied out).
  Phones update automatically the first time you open the app after updating.
  Before this, a phone in a pocket could stop sending to a Private circle.
  See the threat-model note in [End-to-end encryption](design/E2EE.md).
- **Driving tab in Private circles** works for members who use the server, and
  members who keep data on their phone get "Use the server" or "Compute reports
  on this phone" instead of a dead end.
- **Simpler settings.** Settings are grouped (Account, Sharing & privacy,
  Notifications, Driving & safety, Server & data, Phone health, Appearance,
  About) with a search box. Each row has one short line; tap the small (i) for
  the details. Encryption keys, Server processing, Active sessions (This device,
  Older sessions, Sign out other sessions) and Diagnostics were tidied up.
- Wording: "circle" instead of "family" where it means friends too.
- Server: `POST /auth/sessions/current` tells an app which session is its own.

- **Members are on the server by default; they opt out by hand.** On a server set to **Home**, a member of a circle
  that has server processing on no longer has to find "Use the server": the next time they open the app, their own
  phone signs it for them (same signature as a tap, visible in the circle's key log). They see "Your circle uses the
  server so maps, history and driving reports work. Tap to keep your data on your phone." and one tap on **Keep on my
  phone** switches it off and deletes what the server holds of theirs. If they ever chose, nothing is changed again.
- Not applied automatically: circles that **require** server processing (they keep their consent card), child
  accounts, members on an old app (they get it after updating), and servers set to **Cloud** or not chosen (the app
  asks instead).
- Admin: the member default (server or phone, auto-apply on or off; API
  `/api/admin/settings/member-defaults`) and a list of **members not yet on the server** with a message to send
  (API `/api/admin/members-not-on-server`). Circle admins see the same list on the circle's processing screen.
- Joining: the invite preview says "This circle uses the server by default; you can opt out."
- The server can read the data of everyone on it, as before; this changes who presses the button, not what the server
  can read.

- **Better Documents page.** A topic tree you can collapse, an "On this page"
  list that follows you as you read, breadcrumbs, previous and next links,
  search with highlighted matches and recent searches (press `/`), notes and
  warnings in colour, code you can copy, pictures you can enlarge, and a layout
  that works on a phone and prints cleanly.
- **New guides.** [Quick start (5 minutes)](quick-start.md),
  [Concepts](concepts.md) (Normal, Private and server processing, with a
  picture), [Troubleshooting](troubleshooting/index.md), [FAQ](faq.md) and a
  [Glossary](glossary.md). The privacy and chat pages now say the same thing as
  the app.

- **Orbitly on Wear OS watches.** A watch app for Wear OS 3 and newer (Galaxy
  Watch 4 and later, Pixel Watch and others) shows your people, sends "I'm OK",
  SOS (press and hold, 5 second cancel), pause sharing and quick replies, and
  offers a tile and a watch face complication. The phone stays the only place with
  your sign-in and Private-circle keys; Settings, Watch shows the connection.
  Older Tizen Galaxy Watches are not supported. The release gets an extra
  `orbitly-wear-<version>.apk` (the phone app keeps its own `orbitly-<version>.apk`).
  See [Orbitly on your watch](user/watch.md).

- **Apple Watch app (watchOS 9 or newer).** See your circle on your wrist (name, where, how long
  ago, battery), a distance and direction arrow, SOS with press-and-hold and a cancellable
  countdown, I'm OK, pause or resume sharing, quick replies and alerts. Your iPhone keeps your
  sign-in and keys; the watch only shows what it is sent. New under **Settings, Watch**. This
  part is new and was not yet tried on a real watch.

## v0.24.1 (2026-11-08)

- Build fix: the v0.24.0 release files were not produced because of a file-name
  mismatch in the build scripts. Same app and server as v0.24.0, now with the
  `orbitly-<version>.apk`, `.aab` and iPhone files attached.

## v0.24.0 (2026-11-08)

**Orbitly.** 

- **The server does the processing by default.** New circles are Normal (the
  server keeps locations so maps, history and driving reports just work). Private
  is a clear choice: "only phones can read locations".
- **The server joins by itself.** No extra container, no commands, no passwords:
  the server creates its own key on first start and your phone asks "Your server
  wants to join - does the code match?". One tap approves it. The setup card is
  three steps and ends in a green "Server is processing". The old separate
  container stays available under Details.
- **Use the server (recommended) / Keep on my phone.** A one-time question on
  each member's phone in circles where the admin turned the server on. Nobody is
  ever switched on for someone else. "Keep on my phone" means locations are shared
  privately, encrypted from phone to phone, with no reports unless phone reports
  are turned on.
- **Existing Private circles** get a card for the admin: "Let the server do the
  processing (recommended)". Members on an old app get a "needs update" state and
  a message to send, and an "Update available" card in Settings.
- **Switch a Private circle back to normal mode in one tap** (admin), with a plain
  explanation of what is deleted and who is told.
- New Docker volume `server_device` for the server's key (back it up with the
  database). `OPENFAMILY_SERVER_DEVICE` chooses built-in, sidecar or off.
- **Smoother app in Private circles.** Decrypting updates no longer blocks the
  screen, a catch-up draws two map frames instead of hundreds, and each person's
  last known position is remembered on the phone, so a cold start is never blank.
  Phone-side driving reports are now an opt-in switch (off by default).
- **Phone health reports arrive.** The admin Fleet page shows the real app
  version, OS, battery and permission state, and treats a Private-circle phone
  that is sending encrypted updates as alive.

- **OpenFamily is now Orbitly.** The app, the admin web, the notifications and
  the docs use the new name, logo and icon. The project is for any circle of
  people, family and friends alike. Nothing to migrate: your server, accounts,
  circles and app installs keep working, and the app updates in place (the
  Android and iOS package ids and the signing key are unchanged).
- **About screens.** Settings, About in the app and in the admin web show the
  version, the credit "Based on OpenFamily by wheresfrank and contributors
  (AGPL-3.0)", a link to the source code and the open-source licenses. See
  [Credits and license](about/credits-and-license.md).
- **Release files** are now named `orbitly-<version>.apk` (and `.aab`,
  `.spdx.json`); older releases keep their `openfamily-` names and the server
  downloads either. If you filter releases in Obtainium by name, use `orbitly`.
  Some internal names keep "openfamily" on purpose: see [Naming](developers/naming.md).

- Works with app versions 0.20 to 0.24.

## v0.23.0 (2026-11-08)

- **"Why can't I see everyone?"** In Private circles the app now says why a
  person has no location (their phone has not sent an update, has not received
  the key, needs the app updated, or paused sharing) and has a one-tap fix.
  The phone fetches its circle key on its own, sends a first position as soon
  as the app opens, and no longer drops queued updates while offline.
- **Add the server in three taps**: add, compare the four code groups, OK.
  The admin picks a **home** or **cloud** server profile in Settings; the app
  uses it to suggest the right default.
- **Encrypted chat** in Private circles: messages, edits, deletes and photos go
  phone to phone and never to the server's processing. Old plaintext history
  stays readable and an admin can delete it.
- **Documents** page in the admin site, with the guides and screenshots that
  ship with the server, plus an **App versions** card showing who needs to
  update.
- Works with app versions 0.19 to 0.23. Chat encryption needs app 0.23.

## v0.22.1 (2026-11-07)

- Maintenance release: removes unused test helper code so the release build
  passes its checks. No change for families or admins.

## v0.22.0 (2026-11-07)

Per-member privacy ("processing lanes").

- In a Private circle every person now chooses for themselves whether their
  phone also sends data to the server, or keeps it phone-to-phone only.
  See [Privacy modes explained](user/privacy-modes.md).
- The circle admin decides whether server help exists for the circle at all;
  only the person themself can opt in or out of it.
- Phones compute trips, driving events and the weekly summary on the phone for
  people who keep their data off the server.
- The join screen shows how a circle handles privacy before you join.
- Needs app **0.22** for the new screens. Older apps stay safe: they keep data
  phone-only and are asked to update.

## v0.21.1 (2026-11-07)

- iOS build pipeline fixes (unsigned test builds for sideloading). No change to
  the server or the Android app.

## v0.21.0 (2026-11-07)

- **App compatibility window.** The server now supports the last 5 minor app
  versions, shows banners in old apps ("Update required" or "A newer version is
  available") and lists app versions in use in the admin panel
  (Settings, App versions). See [API compatibility](api-compat.md).
- **Family chat improvements.** Sends are no longer duplicated when the
  network is flaky; you can edit and delete your messages; missed messages are
  fetched after a reconnect. See [Chat](chat.md).
- Admin setting "Trust this server by default" and matching prompts in the app.

## v0.20.1 (2026-11-07)

- Backups to S3 can be set up from the admin panel; saved credentials are tied
  to their destination and the address checks were tightened (IPv6).
- A flaky Bubble expiry test was fixed (tests only).

## v0.20.0 (2026-11-07)

- **Scheduled off-site backups.** Optional backup service that writes
  encrypted copies to S3-compatible storage with retention, and an admin
  Backups card with a "Back up now" button. See
  [Backup and restore](backup-restore.md).

## v0.19.0 (2026-11-06)

- **Home Assistant integration**: read-only scoped tokens, signed webhooks, an
  admin Integrations card and a custom component. See
  [Home Assistant](integrations/home-assistant.md).
- **Reliability tools**: phone diagnostics and self-test, "silent phone" and
  late-arrival alerts, and a fleet health page for admins.
- Admin web: consistent page layout, better phone layout, new System health
  page.
- iOS: Secure Enclave key channel, universal-link route and release workflow.
- Private circles: polished admin page and the phone "Trusted server" screen.

## v0.18.0 (2026-11-06)

- **Trusted-server mode** for Private circles: the server can become an
  approved member of a circle, but only when every live member agrees, and
  members can withdraw and have the server's copies deleted.

## v0.17.0 (2026-11-06)

- **Private circles, phase 3**: trust checks on who may see a circle, the
  browser viewer for the admin web, a Dawarich bridge and phone approval of
  every viewer. Security fixes make wrapping keys fail closed.
