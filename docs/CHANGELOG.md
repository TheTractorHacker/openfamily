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
