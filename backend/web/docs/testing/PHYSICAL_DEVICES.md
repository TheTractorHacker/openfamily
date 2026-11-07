# Physical-device test procedures

Emulators cannot prove background tracking, doze behaviour, OEM battery
killers or real GPS. This document is the procedure; results go in the table
at the end.

> **Status: procedures written; physical execution BLOCKED.** No agent has
> access to physical phones. Every result row below is "not run" until a human
> fills it in. Nothing in this document is a measured result. Everything in
> the one-hour run sheet and in the in-app Diagnostics and Self-test screens was
> written and unit-tested without ever running on a real phone: if one of them
> misbehaves on your device, that is a bug to report, not a user error.

## Device matrix (minimum)

| ID | Device class | Why |
|---|---|---|
| A1 | Pixel (stock Android, current release) | Reference behaviour |
| A2 | Samsung (One UI) | Aggressive background limits |
| A3 | Xiaomi/Oppo/OnePlus (OEM killer) | Auto-start / battery saver kills |
| A4 | Low-end Android Go-class device (<=3 GB RAM) | Memory pressure |
| I1 | iPhone (current iOS) | Only after iOS distribution exists (see ../design/IOS_RELEASE.md) |

Record OS version, app version (Settings -> About), battery health, SIM/Wi-Fi.

## Preconditions

- Server reachable over HTTPS; two test accounts in one circle; admin web open to watch the live map.
- App installed from the release APK, signed in, all permissions granted ("Allow all the time" location, notifications, battery: unrestricted).
- Fully charged; screen timeout 30 s; note starting battery %.

## Procedures

### P1. Background tracking (foreground service)
1. Start tracking, lock the screen, leave the phone 60 min stationary.
2. Pass: points keep arriving (admin Devices page "last seen" < 5 min old at every check); no "tracking stopped" notification.

### P2. Killed-app recovery
1. Swipe the app from recents; wait 15 min while walking 200 m.
2. Pass: points resume without opening the app (or document the OEM setting needed).

### P3. Doze / idle
1. Stationary, screen off, unplugged, 8 h overnight.
2. Pass: gap between consecutive points <= the configured idle interval x 2 on A1; record gaps on A2/A3.

### P4. Reboot persistence
1. Reboot the phone; do not open the app; walk 5 min.
2. Pass: tracking resumes within 5 min of boot (or documented limitation).

### P5. Offline queue
1. Airplane mode for 30 min while moving; then reconnect.
2. Pass: queued points upload in order, no duplicates (compare point count with GPX from a reference app).

### P6. Accuracy
1. Walk a known 1 km loop with a reference GPS app running in parallel.
2. Pass: track within 25 m of reference 95% of the time; distance within 5%.

### P7. Geofence arrival/departure
1. Place a 150 m geofence; approach from 1 km, enter, leave.
2. Pass: enter and exit notification each arrive within 2 min of crossing.

### P8. SOS and check-in
Trigger SOS on A1 with screen off; pass if the other account is notified within 30 s. Repeat on cellular only.

### P9. Battery cost
1. 100% battery, unplugged, normal use plus tracking for 8 h on each device; same with tracking off as the control.
2. Record battery drop attributable to OpenFamily from Android Settings -> Battery (app usage %) and `adb shell dumpsys batterystats --charged` if available.
3. Pass: attributable drain <= 5% per 8 h of mixed use (proposed budget; adjust after first baseline).

### P10. Update path
Install vN, then vN+1 over it via Obtainium; pass if tracking continues and no re-login is needed.

## One-hour run sheet (v0.11 to v0.19 features)

For the owner, on real phones. Needs: **two phones** on the same server (call them
**Phone A** = yours and **Phone B** = a family member or a spare; ideally A is Android
and B a different brand), a laptop with the admin panel open, a second account in one
circle, and about 60 minutes. Do the sections in order; the time boxes include waiting.
Screenshot anything marked **[shot]** and note the result in the template at the end.
A step that cannot be done (feature not configured, no second phone) is recorded as
**SKIP** with the reason, never as PASS.

Conventions: "A:" means do it on Phone A, "B:" on Phone B, "Web:" in the admin panel.
Menu names are the ones in app version 0.19.0; if a label differs slightly, find the
nearest one and note it.

### Before you start (3 min)

1. A: Settings, tap the **OpenFamily** version row (note the version), then Settings, **Diagnostics**.
   Expected: the checks load within about 10 seconds and the top banner says either
   "Everything looks right" or lists problems. **[shot]**
2. Fix every red item the screen lists (one tap each) until the banner is green, then
   **Copy diagnostic report** and paste it into your notes. Check the pasted text contains
   no coordinates, no token and no e-mail address.
3. Repeat on B.
4. Web: open **Fleet health**. Expected: both phones listed, each with app version, OS and
   "Self-report ... ago". **[shot]** If a phone shows "Not reported" for battery and
   permissions, it is running an older build; update it.

### 1. Diagnostics and self-test (8 min)

1. A: Diagnostics, **Self-test**, **Run self-test**. Expected, in order:
   Keystore PASS (shows "TEE" or "StrongBox"; "Software" is a finding to note), Vault PASS,
   Private circle encryption PASS, Upload PASS ("server registered it just now"),
   Notifications PASS with a **Confirm** chip, and you must see **two** notifications
   ("local test" and "OpenFamily test alert") within 30 seconds. Only one or none:
   FAIL and note which. **[shot]**
2. A: **Start background test**, lock the phone, put it in your pocket and walk or sit
   five minutes with the screen off, then unlock and reopen the Self-test screen.
   Expected: "Background reporting works". FAIL means the OEM is killing the app: go
   back to Diagnostics and follow the battery advice for your brand, then repeat.
3. A, deliberately break it: Android Settings, Apps, OpenFamily, Permissions, Location,
   choose **Allow only while using the app**. Reopen Diagnostics. Expected: a red
   "Location permission" card whose button opens the permission page; restore **Allow all
   the time** and the card turns green on return. Then Settings, Battery, set
   OpenFamily to **Optimized**. Expected: an orange battery card (with a brand-specific
   button on Samsung, Xiaomi, OnePlus, Huawei, Oppo); restore **Unrestricted**.
4. A: set the phone clock manually 10 minutes wrong (turn off automatic time).
   Expected: Diagnostics shows a clock warning or failure. Turn automatic time back on.
5. A: airplane mode on, reopen Diagnostics. Expected: "Internet connection" red, server
   check "info" not red. Airplane mode off.

### 2. Silent-phone alert (7 min, includes waiting)

1. A (a circle admin): Settings, **Notification settings**, **Silent phone alerts**: set
   your circle to **4 hours** (the shortest choice that is not "Off" for the first test is
   fine; the server default is Off). B: leave the setting alone.
2. The alert needs a few days of history to know B's normal hours, so on a fresh install
   this will not fire. Real test: pick a phone that has been reporting for 3+ days, switch
   it to airplane mode (or power it off) and wait for the threshold plus about 10
   minutes. Expected: A (admin) gets "Phone hasn't checked in ... about N hours" and B
   gets "OpenFamily can't reach your phone" when back online, opening the Diagnostics
   screen when tapped. The text must NOT contain a place or coordinates. With "Show names
   in notifications" off it says "A family member's phone".
3. Expected non-events: the same silence produces **one** alert, not repeats; nothing
   during the recipient's quiet hours (Settings, Notification settings, quiet hours); B
   turning on "Don't alert about my phone" stops it.
4. Record honestly if you could not wait: **SKIP (needs 3 days of history plus a multi-hour wait)**.

### 3. Late-arrival alert (needs weeks of history, 2 min to set up)

1. A: Settings, Notification settings, **Late-arrival alerts**, switch on one saved place
   (only circles that are not Private show places here). Expected: the section exists
   and the toggle sticks after leaving and returning.
2. The alert itself needs at least 5 similar arrivals over 6 weeks. Record **SKIP** unless the
   place has that history; if it does, be late on a weekday and expect one alert to your circle
   about an hour after your usual time, at most two per day.
3. Private circles must not list places here at all. Record whether that held.

### 4. Invite page and joining (5 min)

1. A: open the circle and tap the invite card (or Circles, invite). Copy the link.
2. B (or any phone without the app): open the link in the browser.
   Expected: the **invite page** with install steps, a public **APK download** and a **QR code**,
   served without login. **[shot]**
3. B with the app installed: open the same link. Expected: the app opens straight into
   the join screen with the code filled in. Join. A sees B appear on the map within a minute.

### 5. Names in push, units, person panel (6 min)

1. A: Settings, Notification settings, **Show names in notifications** OFF. B: arrive at or
   leave a saved place (or use SOS-free Check In). Expected on A: "A family member ...".
   Turn it ON on A, repeat: "<First name> ...". Names must appear only for the recipient who
   opted in; B's setting must not change what A sees.
2. A: Settings, units tile: Miles to Kilometers. Expected: the Places radius list, speeds, the
   Driving tab, the weekly summary text and server-written notifications switch units, and the
   choice survives restarting the app. **[shot]** of one screen in each unit.
3. A: tap B on the map and again in the member list. Expected: the **person panel** opens
   (name, place presence, battery, speed, history/driving entries), no crash, back closes it. **[shot]**

### 6. Driving tab and phone-use detection (5 min; passenger only)

**Never operate a phone while driving.** The driver keeps their eyes on the road; a passenger
runs this.

1. A: Settings, **Driving detection**: switch on hard braking/acceleration and **Detect phone use
   while driving** (opt-in, off by default).
2. Take a short drive (10 minutes is enough) with A in the car. The passenger turns the screen
   on and off a few times mid-drive.
3. Afterwards: **Driving** tab. Expected: the trip appears with distance and duration in your
   chosen unit, event chips (brakes, speed), and a phone-use event for the screen-on moments, which
   you can mark **passenger** or **dismiss**. Record whether the events match what happened.
4. The Sunday weekly summary (Sunday 18:00 UTC) cannot be forced; record **SKIP** unless it arrives.

### 7. Place search (3 min)

1. A: Places, add a place, type the first letters of a street near you. Expected: suggestions
   appear within about 2 seconds, local results first, picking one drops the pin in the right
   place. Try a street in another country: results must not be forced to your region only when you
   type the full address. Note the language of the results.

### 8. Passkeys (2 min)

As of v0.18.0 the server side exists (`docs/passkeys.md`) but **no phone or web screen enrols or
uses a passkey yet**. Expected: no passkey option anywhere, and password sign-in still works
on both phones and the web. Record **N/A (no client UI)** otherwise. Do not mark passkeys PASS.

### 9. Private circles (14 min)

Use a throwaway circle, not your family's.

1. A: create a circle and turn on end-to-end encryption (Circle settings, **Private**/Encryption).
   Write down the recovery phrase on paper. Expected: the circle shows "End-to-end encrypted".
2. B: join it. A: approve B's key (compare the safety number or digits on both screens). Expected:
   B appears on A's map only after approval; the Diagnostics screen on both shows **Private circle keys**
   passing (info text about the lock screen is normal).
3. Lock both phones 5 minutes while moving. Unlock. Expected: positions appear on the other phone within
   about a minute of unlocking. Positions taken while locked are delivered late, by design. **[shot]**
4. Web: Admin panel, **Fleet health**: B's row says "Private circle" and shows timestamps only.
   Web, **Encryption keys**: both phone keys listed. The admin map must show **no** position for the circle.
5. **Web viewer.** Web: **Private circles**, create a viewer, choose storage mode "session". Copy the request
   code. A: the circle's settings, **Approve a viewer or bridge**, paste, compare name, fingerprint and
   digits, approve, copy the approval code back into the web page. Expected: the web map shows both members. Revoke
   the viewer from the phone afterwards and confirm it stops updating after the next key change. **[shot]**
6. **Bridge.** Needs a Dawarich and a machine that is NOT the server (`backend/cmd/e2ee-bridge/README.md`): run
   `enroll`, approve on A, `run`. Expected: points appear in Dawarich with no coordinates in the bridge log.
   Record **SKIP** if you have no Dawarich.
7. **Trusted server.** Only if you want the server to read the circle. A: Private circle, **Trusted server**,
   read the warning, consent; B must consent as well. Expected: the circle is labelled "Server can read
   (trusted server)", the admin map shows it, and withdrawing consent on either phone returns it to
   unreadable. Record **SKIP** if the `e2ee-server` sidecar is not deployed. **[shot]**

### 10. Dawarich export (4 min)

Web: **Settings**, Dawarich card: URL, API key, enable. Expected: points from a plain (non-Private) circle arrive in
Dawarich within a few minutes, once each; a Private circle contributes nothing (unless trusted-server mode or the bridge
is on). Disabling stops new points but does not delete what was sent. Record **SKIP** without a Dawarich.

### Wrap up (2 min)

1. Web: **Fleet health** again. Expected: both phones healthy or with findings you already know about. **[shot]**
2. A and B: Diagnostics, **Copy diagnostic report**; attach both reports to your results.
3. Fill in the results table below. Note OS version, phone model, app version and server version at the top.

### What to screenshot (checklist)

Diagnostics (green and with a red item), Self-test results, the invite page, one screen per unit
system, the person panel, the Driving tab trip, Private circle map on both phones, the web viewer map,
the Trusted-server label, Fleet health (before and after).

### Results template

Copy into an issue or your notes. Result is one of PASS, FAIL, SKIP, N/A.

```
Date:            Tester:
Server version:  Server URL host:
Phone A:  model / Android version / app version / battery health
Phone B:  model / Android version / app version / battery health

| #  | Check                                   | Result | Notes / screenshot file |
|----|-----------------------------------------|--------|-------------------------|
| 0  | Diagnostics green on A / on B           |        |                         |
| 0  | Fleet health lists both phones          |        |                         |
| 1a | Self-test: Keystore (level: ___)        |        |                         |
| 1b | Self-test: Vault                        |        |                         |
| 1c | Self-test: encryption                   |        |                         |
| 1d | Self-test: upload and read back         |        |                         |
| 1e | Self-test: two notifications seen       |        |                         |
| 1f | Background test (5 min, screen off)     |        |                         |
| 1g | Diagnostics catches while-in-use perm   |        |                         |
| 1h | Diagnostics catches battery optimising  |        |                         |
| 1i | Diagnostics catches wrong clock         |        |                         |
| 2  | Silent-phone alert (one only, no place) |        |                         |
| 3  | Late-arrival alert / Private not listed |        |                         |
| 4a | Invite page (steps, APK, QR)            |        |                         |
| 4b | Invite link opens app on B              |        |                         |
| 5a | Names in push off/on, per recipient     |        |                         |
| 5b | Units switch everywhere, persist        |        |                         |
| 5c | Person panel from map and list          |        |                         |
| 6  | Driving trip, events, phone-use         |        |                         |
| 7  | Place search                            |        |                         |
| 8  | Passkeys (expected N/A)                 |        |                         |
| 9a | Private circle create/approve           |        |                         |
| 9b | Private updates after unlock            |        |                         |
| 9c | Admin sees no positions                 |        |                         |
| 9d | Web viewer                              |        |                         |
| 9e | Dawarich bridge                         |        |                         |
| 9f | Trusted server                          |        |                         |
| 10 | Dawarich export                         |        |                         |
| P1 | 60 min background tracking (see P1)     |        |                         |
| P2 | Killed-app recovery (see P2)            |        |                         |
| P4 | Reboot persistence (see P4)             |        |                         |

Brand-specific battery findings (what finally worked on this phone):
Anything that surprised you:
```

### Known limits of the in-app tools (so you do not over-trust them)

- Diagnostics reads Android's battery-optimisation state but cannot see vendor extras
  (Xiaomi Autostart, Samsung "Sleeping apps", OnePlus/Oppo/Huawei auto-launch). For these brands it shows
  the guidance as information and opens the vendor screen when the component name exists on your ROM
  version; if it does not, it opens stock battery settings. The vendor screen names were collected
  from community knowledge and are **unverified on real devices**.
- The self-test uploads **one real position** (yours) with source "foreground"; it appears in your history.
- "Background test" proves one 5-minute window, not eight hours of Doze. Use P1 and P3 for that.
- iOS is not covered (no iOS build exists yet).

## Load test (server side)

`scripts/load-test.sh` drives the ingestion endpoint and the live WebSocket
with k6 (pinned Docker image) against a **non-production** instance:

```bash
BASE_URL=https://staging.example.com TOKEN=<access token> DEVICE_ID=<that user's device id> \
  VUS=50 DURATION=2m scripts/load-test.sh
```

It reports request rate, p95 latency and failure rate for `POST /api/locations` and the success rate of WebSocket upgrades on `/ws/stream`. Thresholds fail the run: p95 < 500 ms, errors < 1%. The API caps ingestion at 300 points/min per user, so one token sustains about 5 requests/s; pass `TOKENS`/`DEVICE_IDS` (comma separated) to spread load across test users. Never point it at production or at a family instance with real data: it writes synthetic points under the test account.

Baseline numbers: **not recorded** (no staging instance was available to the agent that wrote this). Record the first run in the table below.

## Results (fill in)

| Date | Device / server | Procedure | Result | Notes |
|---|---|---|---|---|
| - | - | all | not run (BLOCKED: needs physical devices) | |
