# Changelog

What changed in each Orbitly release (published as OpenFamily before the rename), in plain words. The server shows the
section for the version it runs on the admin **Documents** page and on
**Settings, App versions**. Older entries are in the git history
(`git log v0.16.0..`); this file starts at v0.17.

Each release says which app versions it works with. The server keeps working
for the **last 5 minor versions** of the app (see
[API compatibility](api-compat.md)), so you can update the server first and
the phones afterwards.

## v0.26.19 (2026-11-09)

App-only release (the server needs no change). Install over the current app.

- **A phone driving with Orbitly in the background keeps the others' map moving.** Three things could leave someone's dot minutes behind on a drive with the phone locked:
  - At a long red light or in a traffic jam the phone could drop to one location every 15 minutes until it noticed it was moving again. It now stays on the once-a-second request until drive mode really ends, and in the background drive mode ends after 3 minutes standing still instead of 1.
  - In a Private circle every location is encrypted on the phone before it is sent. While driving these were all started at once, so on a slower phone they piled up and the upload waited behind them. Now one is encrypted at a time, at most 10 wait, and when more come in the oldest waiting one is skipped, so the newest position is never late.
  - Uploads now run one at a time and send what is already encrypted first. Locations waiting for a missing circle key are retried at most every 30 seconds instead of before every upload.

  Nothing is ever sent unencrypted in a Private circle.

## v0.26.15 (2026-11-09)

**Fixed: the map stopped updating while someone was driving.** A busy drive makes many location points pile up on the
server. The server sent them to itself in one request that was bigger than the 64 KB default request size, so it was
refused and retried unchanged forever, and the map showed 0 mph at one spot. The Private-circle routes now accept the
sizes their handlers already allowed (batches of locations, and encrypted chat photos). Server only: update the server,
no app update needed. The server catches up on its own once it is running this version.

## v0.26.17 (2026-11-09)

App-only release (the server needs no change). Install over the current app.

- **Places now reach every member of a Private circle that uses server processing.** A place made by someone whose phone uses the server was sealed under the server's key, which other members' phones cannot open, so only that person saw it. Places are now always sealed under the circle key that every member holds, like chat. The server never used places. On first open the app shares your existing places again once, so they show up for everyone. Everyone in the circle needs this version to see places made by someone else this way; ask them to update and open Orbitly.

## v0.26.16 (2026-11-09)

- **Resetting your keys no longer leaves the server waiting for approval.** When the person who approved the server resets their encryption keys (Reset my keys), the reset also removes the server's key, because it belongs to their account. The server now makes its new key right away and the phone that made the reset approves it with its own signature, so there is no second "Your server wants to join" step. The reset confirmation says this before you confirm. If the phone is offline or the server is slow, the usual approval step stays. Members' server-processing choices are signed for one server key, so they still need to be signed again for the new key, as before. Server: the reset handler tells the built-in server device which of its keys it revoked, and the join request names the key it replaces (`replaces`). Update the server first, then the app; an older app keeps showing the approval step.

## v0.26.14 (2026-11-09)

- **See who is charging.** When someone's phone is on the charger, a small green bolt shows on their bubble on the map, and the battery in the People list and on their card shows a charging icon. A charging phone no longer counts as "low battery": no orange warning and no low-battery alert. Works in Private circles too (end-to-end encrypted, like the battery level). It is shared the same way as battery level, so pausing or turning off sharing hides both. Needs the new app on the phone that is charging; older apps keep showing the percentage only. Server: migration 390 adds an optional `charging` column; the API, WebSocket frames and Home Assistant `/members` carry `charging` when known. Update the server first, then the phones. The watch apps do not show it yet.

## v0.26.13 (2026-11-09)

App-only release (the server needs no change). Install over the current app.

- **Places reach every member of a Private circle.** Places saved before the circle's key changed (a new or replaced phone, or Private mode turned off and on) could only be opened on phones that already had them, so other members saw no places. The app now seals them again under the current key when it opens, and the Places screen shows places that only this phone has, with a **Share places with the circle** button. A received place no longer overwrites the stored list.
- **Map opens where you are.** It starts on your last known position, even on a cold start, then moves to a fresh fix. It frames your circle only when your own position is unknown. It no longer opens on a default city or a days-old point, and it never moves once you have touched it.
- **Background updates while your phone is still.** On Android a phone lying still kept sending nothing until the app was opened. It now reports every few minutes. Tracking restarts by itself after an app update, the offline queue is sent on the regular heartbeat, and restart after a reboot only happens if sharing is on.
- **Faster zooming out.** The map loads tiles at the size they were designed for: about 4x fewer tiles per screen. Recenter and cluster animations are shorter.
- **Place labels match your circle.** People are labelled only with places of the circle you are viewing (and family-wide places), and the Places list in the map sheet is scoped the same way.
- **Chat notifications follow "Show names in notifications".** On: "Henry in Family" with the start of the message. Off: only "New message in Family". This applies to normal and encrypted chat, and encrypted chat notifications now also appear when the app is in the background.

## v0.26.12 (2026-11-09)

- **Open Private circles from any browser.** An admin is no longer tied to one computer. Pair one web viewer with your phone once (the existing "Approve a viewer or bridge"), choose a vault passphrase, and from then on unlock from any browser with your password (and 2FA) plus that passphrase. The key is sealed in the browser and the server cannot open it, it exists only in the open tab, locks after 30 minutes idle, on reload and on sign-out, and your phones are notified when a new browser unlocks. Revoking the web key from a phone ends access in every browser at once. Members on the server already show on the admin map without any key. Admins only; switch it off in Settings > Security or with `E2EE_VIEWER_VAULT=off`. **Server operators:** a new file `viewer-vault-pepper` is created in the `server_device` volume; back it up separately from the database backups (lose it and admins set web access up again once). Needs this server version (migration 380); no new phone app needed. See [Web access from any browser](admin/web-access-anywhere.md).

## v0.26.11 (2026-11-09)

Server first, out of the box. Works with every app from 0.22 on; update the server first, then the phones.

- **Server processing is on by default.** A new circle is created **Private, with your server (recommended)** when the server can take part: one tap on Create makes the circle Private, switches server assistance on, makes the server the default for members and signs your own server choice. If the server key still needs your approval, "Your server wants to join" opens right there. Members who join a circle whose default is the server are switched on automatically by their own phone, with a notice, and can switch it off per circle in **Settings > Server & data > Server processing**. This now also applies to servers set to "rented"; a server admin can untick "Apply automatically" under admin web > Settings > Default for new members to ask first. Circles whose admin had already chosen the server as default will switch members who never chose the next time they open the app. Nobody is ever opted in by anyone else: a person's own phone signs it, and opting out is final. For kids, teens and anyone who must not hide their data, tick **Everyone must use the server** (each member consents once on their own phone or leaves). New guide: [Server processing](user/server-processing.md). The Encryption keys row now says the real state ("On for you", "Phone only for you", "Required in this circle: needs your OK").
- **Settings in the admin web are dedicated pages** (General, Server setup, Privacy and processing, Security, Notifications, Backups, Integrations, Updates and about, Account, Appearance) with their own addresses, a left navigation, working Back and Forward, and a warning before leaving unsaved changes.
- **No false "cannot reach healthz".** The Custom domain and HTTPS checks look at the server and its certificate locally first. Opening your own public address from inside a home network often fails (no NAT loopback) even though it works in a browser; that is now shown as an amber hint with what to do, not a failure.
- **Backups are on by default.** `docker compose up -d` now starts the backup service (nightly to `./backups`, 7 daily, 4 weekly and 6 monthly, plus a first backup right away). Manage it under Settings > Backups; add encryption or S3 there. Opt out with `BACKUP_REPLICAS=0`. Existing servers: make sure `./backups` is writable by uid 1000 (or set `BACKUP_UID`/`BACKUP_GID`), then run `docker compose up -d`. Backups are not encrypted until you add a key.
- **Documentation:** Orbitly wording throughout, a README that starts with a quick start, plain-words privacy and backup sections, and fresh screenshots (attention icon, Encryption keys). Repository links point at the existing `openfamily` repository until it is renamed (this fixes the APK builds page default and the source links).

## v0.26.10 (2026-11-09)

- **Encryption keys screen spacing.** The Owner approval card and the groups below it were glued to the line above and to each other; they now have normal gaps.

## v0.26.9 (2026-11-08)

- **Fleet health tidies itself.** Old sign-ins no longer pile up. Once someone has signed in on a newer device on the same platform, any of their older rows that has not been seen for a day is hidden automatically (checked every hour). Nothing is deleted: history and push settings stay, and a hidden row that reports again shows up again. A person's only device, and devices on other platforms, are never hidden. The manual **Hide stale** button still works. Server-only change; no new app needed.

## v0.26.8 (2026-11-08)

- **No more "Add server" when the server is already added.** In a Private circle's settings, once your data is on the server the row reads **Server is processing** (tap it to manage or remove), and the extra "Add server to this circle" button on the invite page is hidden.

## v0.26.7 (2026-11-08)

Same as v0.26.6 with the server-key repair hardened: the server now answers "key revoked" only when the key really is revoked (a database hiccup is a plain error), and a revoked key's secrets are removed instead of archived. Install v0.26.7.

## v0.26.6 (2026-11-08)

- **The server key repairs itself.** When the server's own key was revoked (for example when your account's keys were reset, because the server key belongs to the account that approved it), the server kept retrying the dead key forever and logged "refused the ingest token", so circles showed "no approved server key". It now notices, waits for three answers in a row (about 90 seconds, so one odd answer never replaces a good key), keeps only the old key's public facts in `archive/` inside the `server_device` volume (its seed, session and circle keys are removed), makes a new key and asks an admin phone to approve it again ("Your server wants to join"). The log also says what really happened instead of blaming the token.
- **Circle processing setting is no longer a dead end.** When the server has no approved key for a circle, an admin sees a **Set up the server key** button (it opens the guided "Add server" sheet) instead of being told to ask the server operator. The sheet's wording for a server that has not joined yet is clearer.

## v0.26.5 (2026-11-08)

- **Attention icon instead of banners.** The notices that were stacked across the top of every screen (update, "nobody has sent an update", "Use the server?", the server-join and auto-apply cards) are now one small icon with a count in the top bar, red when something is broken and amber when you have a choice or an update. Tap it for **Needs your attention**: one card per item, one sentence each and one button. Nothing pushes the app down any more. The map's offline notice is a small "Offline · last synced" pill, and the Private circle chip says "Private + server". After **Set this phone up again**, a circle where you had chosen the server offers **Use the server again** (one tap) instead of the first-time question. See [The attention icon](user/attention-icon.md).

## v0.26.4 (2026-11-08)

Same as v0.26.3 (its release build stopped at an analyzer warning, so v0.26.3 has no app files). Install v0.26.4.

## v0.26.3 (2026-11-08)


- **Owner approval for a new phone in a Private circle.** A circle's creator who is its only admin can now approve their own replacement phone after "Set this phone up again", once they turn on **Owner approval** for that circle (off by default, needs the password; members are told each time and the key is marked "approved by the owner without a second admin"). It trades a little security for recoverability: keep your recovery phrase and add a second admin. The "Waiting for approval" card now says what to do and offers Approve as owner, Members or Turn on owner approval. Needs this app version and server; older apps keep working and see an ordinary approval.
- **Sign-in and encryption keys survive updates.** A storage or Keystore hiccup (after an update, a restart, or now and then) no longer reads as "no key", never makes a new key, never deletes one and never signs you out: reads are retried, a copy of the encrypted keys is kept in case the secure store reads empty, writes keep the old key until the new one is verified, and "Set this phone up again" puts the old key aside so it can be brought back. Only the server's "invalid session" answer signs you out. Diagnostics shows a new "Sign-in and key storage" log (reason codes only) and includes it in the copied report. See [Updates](android-install-and-updates.md#sign-in-and-encryption-keys-survive-updates).

## Unreleased

Nothing yet. The owner moves these notes under a version heading when a release is tagged.

## v0.26.2 (2026-11-08)

- **Top banner readable.** The notice banner at the top of the map ("Tap to see why and fix it") no longer draws under the status bar; it clears it, and the map moves down to make room.

## v0.26.1 (2026-11-08)

Fixes for Private circles on Android.

- **Honest errors.** "Can't reach the server" now appears only for real network failures. A problem with this phone's encryption key says so and offers a repair ("Set this phone up again", then restore with the recovery phrase or link from another phone).
- **Background location in Private circles.** The Android Keystore plugin is now registered in every Flutter engine, so the background service can seal positions while the app is closed. Before, they were parked on the phone until the app was opened.
- **Sequence numbers** for encrypted items are read fresh, so the app and the background service never reuse one.
- **Built-in server device** renews its token before it expires, which removes a harmless 401 line from the server log every 15 minutes.
- Unit-preference tests no longer depend on test order; container images in the server-device build are pinned.

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
