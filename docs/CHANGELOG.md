# Changelog

What changed in each OpenFamily release, in plain words. The server shows the
section for the version it runs on the admin **Documents** page and on
**Settings, App versions**. Older entries are in the git history
(`git log v0.16.0..`); this file starts at v0.17.

Each release says which app versions it works with. The server keeps working
for the **last 5 minor versions** of the app (see
[API compatibility](api-compat.md)), so you can update the server first and
the phones afterwards.

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

## Unreleased

Nothing yet. The owner moves these notes under a version heading when a
release is tagged.

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
