# Changelog

What changed in each Orbitly release (published as OpenFamily before the rename), in plain words. The server shows the
section for the version it runs on the admin **Documents** page and on
**Settings, App versions**. Older entries are in the git history
(`git log v0.16.0..`); this file starts at v0.17.

Each release says which app versions it works with. The server keeps working
for the **last 5 minor versions** of the app (see
[API compatibility](api-compat.md)), so you can update the server first and
the phones afterwards.

## v0.26.34 (2026-11-11)

<!-- Written by three branches (reliab, zero-mph, dawarich-backoff); each adds its own bullets under this heading. -->

**Keep tracking alive (branch reliab).** Not tried on a real phone: nothing here was run on the Samsung phone that showed the problem, or on any phone. The Dart parts and the server worker have tests; the Android (Kotlin) parts were only type-checked with the Kotlin compiler against Android API 36 stubs (the Google location classes were replaced by stand-ins) and read line by line, not built into an app and not run. **This does not make Android keep the app alive.** It makes Orbitly exempt wherever the user can allow that, says live when something is not, and tries to restart tracking in every way Android 12 and newer permits.

- **New: Settings, Advanced, "Keep tracking alive" checklist** (also opened by the first-run background prompt, by the onboarding "Background updates" button and by Settings, "Background updates"). Live rows, refreshed every time the app comes back from a settings page: sharing on, the phone's location switch, location "Allow all the time", battery "Unrestricted" (Android's `isIgnoringBatteryOptimizations` and not background-restricted), Android's app power group (`standbyBucket`: restricted or never is a problem, rare a warning), battery saver, notifications, the background service running, whether Orbitly tried to restart itself and was refused, and whether Android recorded a "Force stop" style end in the last 3 days. Each row that is not fine has a one-tap fix (the system's own dialog where one exists, else the app's settings page, else the phone maker's screen). The rows are a view over the same facts and checks as Diagnostics (`evaluateKeepAlive` over `evaluateDiagnostics`), so the two cannot disagree; Diagnostics gained the power group, restart and force-stop checks.
- **Samsung "Never auto sleeping apps" is no longer asked for.** On the reporter's phone, searching that list for "orb" says "No apps". The app cannot add itself to that list and Samsung's list can leave out an app that is already Unrestricted (web reports, **not confirmed** on that phone). The app now says so, only on Samsung phones, and shows a grey "Samsung sleep settings" line when Android reports Orbitly as Unrestricted (otherwise a warning with the one-tap fix). That line is deliberately not green: the app cannot read Samsung's "Sleeping apps" and "Deep sleeping apps" lists, so it asks the user to look at those once, and on a Samsung phone (or another maker with its own sleep setting) the checklist headline reads "Everything Orbitly can read is right" with "One check is yours", never the plain green "set up to keep running". When Android cannot read a required setting (or the check itself fails) the headline says "Some settings could not be read" or "Could not check this phone" instead of defaulting to green. The "Android stopped Orbitly" row is information (not a nag) when tracking is running again after a single stop, and a warning when tracking is down or the stop repeats. The wording says the "No apps" explanation is our belief from web reports, not something confirmed on the reporter's phone.
- **Tracking restarts itself where Android allows it (Android).** New `ServiceWatchdog`: when tracking is wanted (sharing on) and the foreground location service is not running, it asks Android to start it again from: the activity-recognition transition receiver (documented exemption), the 10 minute alarm (allowed when the user set Unrestricted), the system time and time-zone change broadcasts (not verified as exempt), and the server wake-up push (next bullet). Every attempt is journalled in the native journal: `service_restarted_by_watchdog source=...` (a start was *requested*; the service's own `service_created` line follows only if Android really started it), or `watchdog_refused source=... type=<exception class>` (for example `ForegroundServiceStartNotAllowedException`, `SecurityException`) or `reason=no_background_location` / `no_location_permission`. It does not try without "Allow all the time", because Android 14 and newer throw from inside the service in that case. A refusal inside the service (`startForeground`) is caught and journalled as `start_foreground_refused` instead of crashing the app. 30 seconds between attempts. **It cannot help when the app was force-stopped** (Samsung "Sleeping" and "Deep sleeping" apps, or the user): Android sends such an app no broadcasts until it is opened.
- **The 10 minute alarm now survives the service dying.** It was a repeating inexact alarm armed only by the service. It is now a chain of one-shot `setAndAllowWhileIdle` alarms: each firing arms the next one first, so it keeps going when the service is gone and can fire in Doze (Android allows about one per nine minutes per app while idle). It is removed when the user stops sharing, including when the service was not running at that moment (before, that stop left the alarm and the movement registration behind). The alarm stays inexact on purpose: `SCHEDULE_EXACT_ALARM` and `USE_EXACT_ALARM` are restricted on Google Play to alarm-clock and calendar apps and are **not** declared, so there is no new Play policy exposure. A heartbeat alarm that fires with the service gone now first tries the restart instead of only writing `heartbeat_dropped`. A normal firing writes no journal line (an `alarm_fired` line alternating with refusal lines would have pushed the lines that matter out of the 40-line journal within about 3 hours); only a restart or a refusal is journalled.
- **The location-request push also wakes tracking.** When the phone receives the existing `location_request` command (UnifiedPush, direct channel, APNs path unchanged), the app now also asks the Android side for the same restart (`TrackingWake`, `LocatorPlugin.ensureRunning`; journal `push_wake result=...` when it was not already running). Honest limits: the direct channel is a connection held by the app process, so it cannot wake a dead process; UnifiedPush can (the distributor starts the app) but is not high-priority FCM, so Android lets the restart through only if the app is exempt (Unrestricted); a force-stopped app receives nothing.
- **Server: quiet phones are asked to report without anybody watching (server change, new migration 000425).** Before, the server asked a quiet member's phone for a fix only while another family member happened to open the map. `RunStaleWake` now looks every 5 minutes for Android devices of members who are sharing in a live circle, are not in a paused-sharing window, whose last report or heartbeat is older than 30 minutes (and younger than 24 hours; 30 so the normal 10 minute heartbeat plus Doze slack does not look quiet), and sends the same `location_request` command to that one device (the member's newest Android device only; never their other devices; not iPhones). At most one ask per device per 15 minutes, claimed with one atomic update, recorded on the device row (`devices.last_stale_wake_at`, `stale_wake_count`); after 8 unanswered asks in a row it stops until the device reports again; and at most 12 asks per device in any rolling 24 hours (`stale_wake_day_start`, `stale_wake_day_count`), which a report does not reset, so a healthy phone that sits in Doze and answers every ask is not pushed and made to take a GPS fix every half hour around the clock; nothing is sent when 5 or more devices (and at least half of the active ones) look quiet at once (treated as a server or network outage); at most 50 asks per run. Tests: `stale_wake_test.go`. Not done: showing these asks in the admin page, a setting to turn it off, iPhone wake-ups.
- **Docs.** `docs/user/battery-and-permissions.md` replaces the instructions to find Orbitly in Samsung's list and describes the checklist; no instruction in the user docs needs a computer or adb.

Not verified: anything on a real phone; that Android 17 lets the alarm, transition or push contexts restart the service (the context list is from Android's documentation for Android 12 to 16); that Samsung hides an Unrestricted app from its picker on that phone; that the Kotlin changes build into the app; the iOS and Play side of the package-id change.

## v0.26.33 (2026-11-11)

App-only release (the server needs no change). Install over the current app. **Not tried on a real phone**: nothing here was run on the phone that showed the problem, or on any phone. The Dart parts are covered by unit tests; the Android (Kotlin) parts were only type-checked with the Kotlin compiler against the Android API 36 stubs and read line by line, not built into an app and not run.

What was reported. A Samsung phone (SM-S948U1, Android 17) stopped uploading at 22:36 UTC exactly where the foreground app showed it driving at 71 mph, that is, when the app left the foreground; uploads that day were also sparse (16 to 35 per hour). A read-only review of the code concluded that the background service or the app process was most likely ended by Android, and found that the app had no way to notice that, recover from it quickly, or say why afterwards.

**What this release cannot do.** It does not stop Android from ending the service or the process, and nothing here is a fix for that. It makes the app recover sooner when the person looks at it again, and it makes the next occurrence explainable from the Diagnostics report alone.

- **The service is started again when the app comes back.** On every resume of the map (Android only), if sharing is on and "Allow all the time" is granted, the app asks whether the background location service is running and starts it if it is not (`TrackingResume.onResume`). It never starts it when sharing is off or the permission is missing, does not start a second time right behind another start (20 second guard), does nothing while a check is already running, and does not start on a guess when the running state cannot be read. It writes `service_restarted_on_resume` to the tracking journal. The plugin's own start is also a no-op when the service already runs.
- **Why the process ended, in the report.** The Diagnostics channel returns Android's `ApplicationExitInfo` for this app (last 8 entries, Android 11 and newer): time, reason (`FREEZER`, `LOW_MEMORY`, `USER_REQUESTED`, `CRASH`, ...), importance, status, process name and Android's own short note. The report prints them as **Recent process exits** with the time in UTC only (no local time or time zone, because the report is meant to be pasted publicly; convert to your own time yourself). Older Android, or an older build without the native method, prints "unavailable". It also prints the app standby bucket (`UsageStatsManager.getAppStandbyBucket`, Android 9+) and whether battery optimisation is ignored.
- **Failures are counted instead of swallowed.** The empty `catch` blocks of the background location and heartbeat callbacks (and the background drain, post, profile and registration paths) now record the exception TYPE only (never its text, which can name a host or carry a coordinate) with a time, and per UTC hour the counters received, dropped, parked, posted, credential failures, seal errors and heartbeats ok/failed. Each isolate writes only its own preferences key (`tracking_stats_v1_app` / `_bg`) and the report sums them, so one cannot overwrite the other; the background isolate writes at most every 15 seconds (errors every 3), so a fix per second does not mean a write per second. The report shows **last_upload_ok** (a location upload that the server accepted; a heartbeat answer does not count), **last_seal_or_identity_error**, **last_callback_error** and the last 12 hours of counts. The native service no longer swallows exceptions silently either (`method_call_error`, `location_dispatch_error` with the exception class name).
- **A short tracking journal.** About 100 lines at most, no coordinates: app paused and resumed (with how long it was away), service start and stop requests with the reason (`sharing_off`, `sign_out`), start skipped for a missing permission, permission changes, the background isolate starting (a new isolate means the engine or process was recreated), `service_restarted_on_resume`, `background_drain` and, from the Android service itself, `service_created`, `service_destroyed` (with `reason=requested` or `reason=not_requested`), `service_restarted_by_os`, `restart_stopped` (with the reason), `task_removed`, `trim_memory` (only the serious levels), and `heartbeat_dropped` (the 10 minute liveness alarm fired but there was no background engine or no heartbeat callback, so the tick was thrown away). Repeats of the same line are folded into one with a count. The Dart journal is two preferences keys (one per isolate); the native one is its own small preferences file (`orbitly_tracking_journal`, 40 lines) that the Diagnostics channel reads. The journal is the last part of the report.
- **The background no longer parks fixes forever for an unreadable key.** When the background isolate cannot read this phone's identity (for example the vault was damaged and the foreground has since repaired it), every heartbeat tick now reads the identity again (it is never remembered as failed) and, as soon as it can, seals the parked fixes of Private circles (without needing the network), then uploads. This runs after the heartbeat is sent, never while the app is open (the app seals them itself, and the two cannot share the queue safely), is limited to 20 seconds and to 100 fixes per tick, so a stuck call cannot hold back the "last seen" heartbeat and a process ended mid-drain loses at most 100 fixes. It records `background_drain_blocked reason=...` while it cannot and `background_drain waiting=N sealed=M left=K` when it did. There is no repair in the background: the foreground repairs, the background only picks up the result. How the background reads its identity (the account note, `storedUserId`, not the profile) is unchanged.
- **Where the report is.** Settings, Advanced, Diagnostics, Copy diagnostic report. The Diagnostics screen and the report are otherwise unchanged. The fleet report to the server is unchanged.

Not done on purpose, and to be considered next:

- A **native watchdog** that restarts the service by itself (an alarm or a job). Not added: since Android 12 an app that is not visible may not start a foreground service from the background (with narrow exceptions), so a restart from an alarm can be refused and fail silently, and it can fight the system's own decision to freeze or stop the app. It needs the exit records this release collects to decide whether it would even help.
- Changing request intervals or speed profiles. Not touched: the sparse uploads of that day (16 to 35 per hour while driving) are not explained yet; the new counters (received versus dropped versus posted per hour) are there to say whether the phone received few fixes or the callback dropped them.
- A Samsung-specific check for the "Sleeping apps" and "Deep sleeping apps" lists (Android cannot read them).

Not verified: anything on a real phone; that `ApplicationExitInfo` entries on that phone name the cause; that the foreground can start the service on resume under Android 17's rules (it is the visible app, which is allowed, but it was not run); that the Kotlin changes build into the app (only type-checked standalone against the Android 36 stubs; the Google location classes were not available to the check, so the lines that use them were not checked, and none of them changed). Tests added: `test/services/diagnostics/tracking_health_test.dart`, `test/services/diagnostics/tracking_journal_stats_test.dart`, `test/services/tracking_resume_test.dart`, `test/services/e2ee/background_drain_test.dart`, `test/services/background_callbacks_visibility_test.dart`.

## v0.26.32 (2026-11-10)

App-only release (the server needs no change). Install over the current app. **Not tried on a real phone**: the phone that showed the problem was not available, so the repair is checked only against a fake key store and a fake server in tests.

What was reported. After v0.26.31, the **Encryption keys** screen of one phone said "The key is stored, but the note of this phone's id that belongs to it is damaged. Nothing was changed. (Reason: device-id-format.)". That reason means: the key (seed) is stored, and the stored note of this phone's id (`device_id`) is there but is not readable text. A device id is a UUID string, which is always readable text, so the stored bytes are not what the app wrote. **How the damage happened is not known.** The log of that phone shows a reset at 03:09 on an older build, a new identity created, and half a second later a read that saw a key without its device id. That fits a torn or swapped write, a copy of another entry's bytes, or a mismatch between the key store's two copies, but none of it is proven; the forensics below are there to tell us next time. The key size of that phone was not yet confirmed either (the check for it comes after the id check).

What changed.

- **A missing or damaged device id is repaired by itself, without a reset and without touching the key.** `E2eeService.repairDeviceId` applies when the seed is stored with 32 bytes and the id note is missing, empty, all zero bytes or not valid text. It asks the server for this account's keys and accepts only ONE active key of kind `device` under the signed-in account whose public keys and fingerprint are exactly the ones the stored seed derives; the server's id for that key is written back. Zero or several matches, a revoked key, a key of another account, keys with other public keys, a note naming another account, a seed of the wrong size, no signed-in account, no answer from the server: nothing is written. Right before the write it looks again: the seed must still give the same public key, nothing may have been erased or replaced meanwhile (the same epoch check as the account-note repair), and the id note must still be damaged (somebody else may have repaired it). Only the `device_id` entry is written. The seed is never written and nothing is wiped or put aside. A vault read that fails is never repaired (it is reported as before). Two callers at once (for example the screen and the background service) share one repair. A damaged account note next to it is still repaired by the existing owner repair, after the id.
- **The id must be vouched for by its signature, and written back for real.** The server's record counts only when its registration signature verifies (a key registered by itself is signed by this phone's own key, which the server does not have; a key added by another device names a registrar that the account lists with exactly the key that signed), the id is a lower-case UUID, and, after the write, reading the entry back gives the id (the vault keeps two copies; a write that only reached one is reported as `notSaved`, not as repaired). A failed save is reported as such ("could not save the id, restart the phone") instead of as a connection problem. `identity()` also re-reads the seed after the repair and starts over if another process replaced the key meanwhile, and both note repairs check the epoch again right before writing. The screen names the note as missing or damaged by the real cause and hides Repair when the stored key has the wrong size.
- **`identity()` runs it inline.** This key state means the phone cannot work at all, so waiting for the server is right (same 15 second network limit as the damaged-account-note repair). When the repair cannot be done it throws the same problem as before, now with the result in the storage events (`identity_unreadable cause=device-id-format repair=notOurs`). After "the server could not be asked" it tries again after a minute, after "the server does not list this key" after 15 minutes; **Try again** and **Repair** on the Encryption keys screen ask at once. The background service does the same when it has an account and a working connection, and otherwise waits for the app to have repaired the same vault.
- **What was not changed.** A device id that is readable text but not a UUID is left alone (it is not proven damaged). An id that is only empty, or only zero bytes, counts as damaged.
- **The damage is now described in numbers.** The storage events get `device_id_damaged was=missing|garbled len=<bytes> equals_seed=<true|false> equals_owner=<true|false> all_zero=<true|false>` (is the stored value as long as a key, is it byte for byte the stored key or the account note, is it all zero), then `device_id_repaired was=... len=... equals_seed=...` or `device_id_repair_refused reason=unknown|revoked|kind|mismatch|ambiguous|other-account`. Never the bytes or the ids; each distinct line at most once per half hour.
- **Encryption keys screen.** For this problem it shows the title "This phone's key is stored, but the note of its id is damaged", says what **Repair** does (the id is written again, only after the server confirms which id belongs to this phone's key), and offers **Repair**; **Try again** repairs too. When the server has no record of the key it says so in plain words and that the way out is **Set this phone up again**. If it works, the screen loads normally.
- **Diagnostics.** The delivery warning for `flush_unreadable:device-id-format|missing` now says the note is damaged or missing, that opening the app repairs it once the server confirms the key, and that Encryption keys has a Repair button. The startup self-check says `identity=bad(device_format)` also for an empty or all-zero id note (it still never writes).

Not verified: that the phone of the report has the state reproduced in the tests (valid 32-byte key, 32 non-text bytes as the id, account note fine, server lists exactly that key as active); that the repair works against the real server and the real Android key store (including its second copy of each entry, which could bring the damaged value back); how the damage happened; the key size of that phone; the timing between the app and the background service. A device id that is wrong but happens to be readable text is not detected. Tests added: `test/services/e2ee/device_id_repair_test.dart` (the state of the report, a missing id, an id equal to the key, all-zero and empty ids, both notes damaged, no repair for readable text, every refusal listed above, offline and the retry times, an erase or another key during the server round trip, two callers at once, a healthy phone, the screen). Two older tests that expected "refused" for a key the server does list were changed to use a key the server does not list.

## v0.26.31 (2026-11-10)

App-only release (the server needs no change). Install over the current app. **Not tried on a real phone**: the phone that showed the problem was not available, so the repair is checked only against a fake key store and a fake server in tests.

What was wrong. A phone showed "This phone's encryption key can't be read" on **Encryption keys**, **Private circle delivery** said `flush_unreadable` with 10 positions parked, and yet the startup self-check said `identity=ok` and the Diagnostics key check passed. Three things came together:

- **The self-check and the Diagnostics key check looked at too little.** They read the key and the phone's device id, but not the note of which account the key belongs to (`identity_user`), and did not check the content (key size, readable device id) the way the app does when it uses the key. So they could say fine while the app refused the key.
- **The background part of the app needs that account note; the foreground does not.** The background service that sends positions while the app is closed cannot ask the server who is signed in, so it reads the account from that note. With the note missing it stopped with "empty user id" on every run, and every position stayed parked. The foreground takes the account from the profile, so it did not care and nothing ever wrote the note back. This is reproduced in a test (`test/services/e2ee/owner_note_repair_test.dart`): key and device id present, note missing, self-check `identity=ok`, background refused, foreground fine.
- **Why the note was missing is not known.** The log of that phone shows a reset ("Set this phone up again") at 03:09 followed half a second later by a read that saw a key without its device id. The three entries of a new identity were written one after the other with the key first, so a read, or a write that failed or was cut off, in between leaves exactly such a state. That fits but is not proven.
- **The screen on that phone is not explained.** In the code, a missing note does not make the foreground refuse the key, so it does not account for the Encryption keys message on that phone. Which other check failed there could not be read from the phone's log, because the cause was never logged. This release makes the next report say it (see "The cause is now recorded"). If the screen still shows the message after this update, the cause line in Diagnostics names the entry that failed.

What changed.

- **A missing, empty or damaged account note is repaired by itself, without a reset.** When the key and the device id are fine and the server lists this phone's key as active under the signed-in account with exactly the public keys the stored key gives, the app writes the account id back (`E2eeService.repairOwnerRecord`; the foreground starts it when the key is first used and does not wait for it, so a phone with no network is not slowed down; again every minute while the server could not be asked, every 15 minutes once the server said the key is not ours to claim, and after registering the key; a damaged note, which cannot be told from another account's, does wait for the server). Before it writes, it checks again that the key and the device id are still the ones it confirmed, so a sign-out or erase during the server round trip leaves no stray note and no stale cached key. The key and the device id are never changed or deleted. A note that names another account is never adopted and never overwritten (the existing rule that puts another account's key aside still applies). A key the server does not list under the account is not given a note. A vault read that fails is never "repaired". An empty note used to be taken for "another account" and made the app put the key aside; it is now treated like a missing one.
- **A new identity is written device id, account note, key last, and put aside or restored in the same order.** Restoring an archived key also brings back its device id and account note over the leftovers of a create that failed before it wrote the key, so the restored key is never paired with a new device id. A reader that sees a key therefore sees the rest, and a write that fails midway leaves no key (the next call creates cleanly) instead of a key without its device id. Creating is now one caller at a time and never replaces a key that appeared meanwhile. This only matters when there is no key; a stored key is never rewritten.
- **The cause is now recorded.** Every refusal to use the key is written to the storage events (reason codes only, no ids or key bytes): `identity_unreadable cause=empty-user-id owner=missing`, `identity_read_failed which=owner ...` (which entry: key, device id or account note), `identity_partial`, `owner_repaired`, `owner_unconfirmed`, `owner_repair_refused reason=...`. Each distinct line is written at most once per half hour. The **Private circle delivery** line now shows the reason, for example `flush_unreadable:empty-user-id`, with a plain sentence in the Diagnostics warning: a read failure says the phone tries again, a lost key storage or a key of the wrong size says so and points to Encryption keys.
- **The startup self-check reads the account note and the content.** `identity=ok owner=ok|missing|empty|garbled|unreadable(...)`, and `identity=bad(seed_len)` or `bad(device_format)` for a key that opens but cannot be used. It still never writes. The Diagnostics key check now also asks the app whether it can use the key, so it can no longer pass while the Encryption keys screen refuses it.
- **Encryption keys screen.** It no longer says "Open Encryption keys" while you are on it (the short message used elsewhere keeps that sentence; the screen has its own). When the cause is known it says it in words (for example "This phone lost the note of which account its key belongs to", with a **Repair** button that does the repair above and says what it found), and **Try again** re-runs the check and the repair. The long "stored key cannot be used as it is" sentence is gone for causes where the key is known to be intact; **Set this phone up again** is still there, with a note that it is the last resort.

Not verified: that the phone of the report is in the "note missing" state (its vault could not be read); that the repair works against the real server and the real Android key store; that the Encryption keys message of that phone has the cause fixed here (see above); the two-process timing between the app and the background service. Tests added: 21 in `owner_note_repair_test.dart` (missing, empty, damaged and other-account note, key of the wrong size, key without device id, read failures, server unreachable, key not listed by the server, a reader during creation, the self-check lines, the delivery code, the screen).

## v0.26.30 (2026-11-10)

App-only release (the server needs no change). Update the phone app and the Wear OS watch app. **Nothing in this release has been tried on a real phone or watch**: there is no emulator or watch on the build machine, so only layouts rendered in tests and the arithmetic are checked.

- **Screens redrawn to look calmer and line up** (trips, Security and Encryption keys, Link another phone, circle processing rules and Server processing, the circle list on the map). One left edge of 16 dp (12 on narrow screens) for titles, rows, group headers and notes; rows are at least 56 dp with one short second line, and the longer explanation sits behind the (i) button with its facts unchanged. Details and the problems each screen had are in [UI polish 2](ux/UI_POLISH_2.md).
  - **Trips:** the four numbers (Distance, Duration, Top speed, Average) sit in equal columns, two and two on a narrow screen, never three and one. The Driving report row and the "Processed by server" chip scroll with the list instead of sitting on top of it. Trip and driving cards are flat in both themes (the grey corner shadow in the light theme is gone).
  - **Circle processing rules:** the four choices are plain radio rows, titled "Processing rules" and "Server help"; the (i) only where a choice has a consequence. A short line says the server can read the data of members who allow it. "Positions may not arrive until then" replaces a promise the code does not make.
  - **Security:** grouped as Sign in, Encryption, Your data; the two key rows no longer share an icon.
  - **Circle list on the map:** one line of facts per circle, no repeated "Location sharing: on" chip, and Details and Create are normal rows.
  - Shared pieces for all screens: stat strip, chip row, radio row and settings list (`widgets/ds`). The rows of every screen that uses a row group moved from a 20 dp to a 16 dp inset. Other screens with known 344 dp overflow (member detail, Places, weekly summary, driving report cards) are not changed yet.
- **Samsung "Never sleeping apps" does not list Orbitly: the battery button now goes straight to Orbitly.** It opens the system's one-tap "Allow Orbitly to run in the background" dialog for this app; if the phone refuses it, Orbitly's own app page (where Battery > Unrestricted does the same job), and only as a last resort the general battery list. The Samsung steps in Diagnostics, the permission screen and [Battery and permissions](user/battery-and-permissions.md) now start with Settings > Apps > Orbitly > Battery > Unrestricted. Not seen on a Samsung phone.
- **Wear OS: the direction arrow now follows your wrist smoothly.** Before, the watch read its compass 5 times a second and nudged the arrow after each reading, so it moved in steps and lagged. Now, while the Distance and direction screen is open and awake, it reads the rotation sensor at about 50 times a second and eases the arrow every display frame (a critically damped follower: no overshoot from rest, about 0.13 s to cover most of a turn, always the short way round, so 359 to 1 degrees is a 2 degree turn). The compass stops when the screen closes, the watch goes to always-on mode or you leave the screen, and no frames are drawn while nothing moves. A small mark on the ring shows north.
- **True north, and a steadier arrow when the wrist is raised.** The heading now includes the local magnetic declination (from Android's built-in model at the watch's last known position; no permission added, nothing sent anywhere), so the arrow no longer points a few degrees off in places where magnetic and true north differ. If it cannot be worked out the screen says "(approx. north)". When the watch is tilted up the compass blends smoothly from the top of the screen to the axis out of the back of the watch, so the arrow does not jump when you raise your wrist, instead of getting unstable. It also allows for the display being turned 180 degrees (other-wrist setting). The presence messages to the phone now leave in order, so the 2 second request cannot be undone by an older message overtaking it.
- **Calibration hint.** If the watch compass reports low accuracy for a moment, the arrow fades and the screen says "Move your wrist in a figure 8" instead of showing a confident wrong arrow.
- **Fresher position while you look for someone.** While the direction screen is open the Wear OS watch sends `visible` with the argument `finding` (the same request the Apple Watch makes), so the phone sends a snapshot every 2 seconds instead of every 5. The minute-by-minute `visible` repeat now carries the same argument, otherwise it would have switched the faster rate off again. The watch re-reads its last known location every 15 seconds while the screen is open (it never starts GPS), and a new position for the other person now glides in over about half a second instead of making the arrow jump. The phone code is unchanged: the Dart side already accepted `finding` from any watch.
- Not changed: the arrow is still only as fresh as the other person's phone reports, and the watch's own position is the last one Android has cached.

Not verified: how smooth it feels on a real watch, whether the sensor axes behave as expected on different models and wrists (left or right), the battery cost of 50 Hz sensing while the screen is open, and the figure-8 hint's thresholds. Tested on a computer: 34 new unit tests for the follower, wrap-around, tilt switch, declination cache, calibration gate and the `finding` argument, and the debug watch app builds.

## v0.26.29 (2026-11-10)

App-only release (the server needs no change). Install over the current app; the Apple Watch app updates with the iPhone app (let the watch app update too). Nothing in this release has been tried on a real phone, foldable or watch yet.

- **Settings, in six groups.** **Account, Circle, Notifications, Privacy and security, Devices, About.** The rarely needed things are folded under **Advanced** at the end (Diagnostics, Server address, Map style, Accent colour, Distance and speed units, Delete account). Nothing was removed, and the search box still finds every setting, Advanced ones included (several words narrow it down). Rows keep to one short line; the long explanations sit behind the (i) button. **Link another phone** is now also under **Devices**. See [Settings at a glance](user/members-and-devices.md#settings-at-a-glance).
- **Narrow and folded screens.** On screens narrower than 360 dp (the Galaxy Z Fold's cover display is about 344 dp) and at large text, settings rows drop their little icon tiles and use a smaller margin so the words and the switch get the room. Settings and Notifications now use one centred column of at most 600 dp on wide screens (the Fold's inner screen). Settings, Notifications and Link another phone are tested at 344x882, 360x640, 412x915 and 673x840, at normal and 1.5x text, and fail on any overflow. Other screens were not changed; see below.
- **Quiet hours no longer disappears and comes back as you scroll.** The Notifications page was a lazy list: scrolling away threw Quiet hours (and the two sections after it) away, and scrolling back fetched them again, showing nothing until the answer came. The page is now built once and keeps its sections, and Quiet hours has its row from the first moment (the switch is disabled until the answer arrives; with a **Try again** if the load failed). The first time you open the page, if Quiet hours is on, the switch turns on and the From and Until rows slide in when the answer arrives, which moves the sections below down a little; the Silent phone alerts and Late-arrival sections also grow in when their data arrives. Scrolling away and back no longer causes either. The per-circle requests for Silent phone alerts now run together instead of one after another.
- **Keep me signed in says what it does.** With the switch on, Orbitly saves the password you sign in with in the Android Keystore or iPhone Keychain (this phone only) and uses it only when the server has ended your sign-in and no refresh works. **It cannot do this for an account with two-factor sign-in**, because it cannot enter the code: nothing is saved for such an account and you are asked to sign in. The switch now shows which of four states applies (off, active, saved at your next sign-in, not possible with two-factor), and turning it on later saves nothing until your next password sign-in. Changing your password or logging out deletes the saved password. This is covered by tests of the real sign-in, the silent sign-in and the storage.
- **Lighter drawing in Settings.** The dotted background behind Settings (and the welcome and start screens) was drawn as about 10,000 separate dots and recorded again while you scrolled; it is now one drawing on its own layer, and the search box stays at the top instead of being rebuilt each time it scrolled back into view. Measured in a test harness (one draw call, no repaints and no platform calls while scrolling); not yet measured on a phone, and it does not explain slowness elsewhere in the app.
- **Link another phone, redone.** The screen first asks **Which phone is this?** and then shows one step at a time with one button: make a code on the new phone, check and approve it on the phone you already use (**They match: approve** only when both show the same check code), then paste the answer back and see **This phone is linked**. Codes can be shared, copied or shown as a QR code, pasted codes may contain line breaks, the long check number is under **Details**, and **Reset my keys** is folded under **No other phone?**. Back goes one step back; on the two steps that show a code it asks before leaving, because the code is lost. See [Link another phone](user/members-and-devices.md#link-another-phone).
- **Error messages say what is actually wrong.** "This phone is offline" appears only when the operating system reports no network at all; when the phone is online but the server does not answer, the message says your server did not answer and may be restarting; a timeout says so. Other causes get their own sentence and next step: your sign-in ended, the server refused (with its reason), the server is busy, a server error (with its code), this phone's encryption key is missing or locked, an incomplete pasted code, or a problem on the phone itself. Chat, circles, trips, crash reports, inbox, joining a circle, places, the profile and the map load now use these messages instead of "check your connection". A Wi-Fi network without internet reads as online. See [What the error messages mean](user/when-the-server-is-down.md#what-the-error-messages-mean).

Known, not changed here: at 344 dp these screens still overflow and need their own fixes: the member detail screen (section header action and trip card), Places (three row buttons), the weekly summary member header, and the driving report widgets (week/month row, event chips, report cards, phone driving row).

- **Apple Watch: the direction arrow now turns with your wrist, like Precision Finding.** The watch reads its own compass while the Distance and direction screen is open and awake, and draws the arrow at 30 frames a second, easing between readings and always turning the short way round (359 to 1 degrees no longer spins the long way). The ring with the N turns the other way so north stays put. The compass stops when the screen closes or the wrist goes down. If the compass is not ready the arrow points with north at the top as before. Under about 15 m the screen says the person is close instead of showing a jittery arrow, and it shows how old their position is ("Updated 12 s ago"). The watch asks for location permission once so the compass can point to true north.
- **Fresher position while you look for someone.** While the direction screen is open the iPhone sends the watch an update every 2 seconds instead of every 5 (`visible` with the new argument `finding`; Wear OS is unchanged). The arrow is still limited by how often the other person's phone reports.
- **Less lag on the rest of the Apple Watch app.** A new snapshot is decoded and saved off the main thread, an identical one is skipped, and the people list redraws only the rows that changed. The watch also says it is on screen again once the connection to the iPhone is up, instead of waiting up to a minute.

## v0.26.28 (2026-11-10)

**Update the server first, then the phones.** The server part works with every app version of the last five minors; phones on older versions keep today's behaviour (a reset replaces the server key and an admin phone approves the new one).

- **An owner key reset no longer replaces the server's key.** After a reset the owner's new phone can keep the same server key by signing for it (a new key-log entry, "server key attached"). Only that exact key, only for the owner's own account, only with the new phone's signature; any other case revokes the key as before. The server's own files, keys and history are untouched, so the other family members' choices stay valid and nobody has to do anything. (Server part; the phone part is in the app.)
- **"Require server processing" is enforced again, with one narrow catch-up window.** In a circle that requires server processing the server refuses the phone-line positions (and history, trips and other results) of a member whose own phone has not signed the server choice; check-ins, events and chat always go through. Only a member whose own signed server choice (their live phone key, not expired) became out of date because the server key was replaced is still relayed, and only for 72 hours after the replacement completed (measured by the server's own record of it; a server restart that pins the same key again does not count as a replacement). Never for a member who never chose, withdrew, or whose phone key was revoked, and never after the 72 hours. The server still reads only members whose own phone signed the server choice. (This reverts the first draft of this release, which let a catching-up member send on the phone line without limit.)
- **The server key directory is protected and documented.** It lives on the `server_device` volume, is created once and never regenerated; a unreadable key file is an error, not a new key. `scripts/backup.sh` saves it next to an encrypted backup (never unencrypted) and `scripts/restore-server-key.sh` puts it back; the nightly backup service does not include it (see Backups).
- **New: "Replace the server key"** (`POST /e2ee/server-device/replace`), the only deliberate way to change the key: a server admin whose account holds it signs with their phone; the new key waits for the usual approval.
- The Server processing status now says whether the circle's policy is still backed by a live admin phone, and which members hold an out-of-date choice (`pref_stale`) or are inside the 72 hour catch-up (`catching_up`), and which member waits for an admin phone to sign the policy again (`waiting_for_policy`).
- **App: "Require server processing" is one switch for the owner, and members are never asked.** In the circle settings an admin of a Private circle with the Orbitly server turns it on (it is on by default for a new circle). Every member's phone then signs its own server choice by itself, the first time it runs and whenever the server key or its generation changes; members see "Your family admin requires server processing." and no opt-out. The owner sees who is on the server and who is still catching up. The honest consequence: the admin can force it, and the only way out for a member is leaving the circle. An existing circle keeps its setting. The old "consent required" dead end (the phone sealed nothing) is gone: the phone signs by itself, and a position refused as `required_server` makes it sign again at once (check-ins and alerts are never refused).
- **App: the circle repairs itself after an owner reset or a phone replacement.** The owner's new phone keeps the server's key by signing for it, signs the circle's settings again with a new key generation wrapped to everyone and to the server, and signs its own choice; every other member's phone signs its choice again by itself if it names a replaced key. If the server refuses a server copy of a position (its choice names a replaced key), the phone sends the family copy at once (no position is dropped, nothing is sent in the clear) and renews its choice. A leftover background process that still uses a revoked key switches to the new one.
- **App: the Server processing screen no longer ends on "Something went wrong".** A failure now says what happened (no connection, waiting for approval, the server's answer could not be read, this phone's key cannot be opened, ...) and the screen still shows the circle with a plain note while the phone keeps sending. "You appear to be offline" is shown only for a real connection failure.
- **App: Diagnostics "Private circle delivery" is in plain words** (what is wrong and what the app does about it) and says nothing about codes, lanes or keys; the technical lines stay in the copied report.
- **The phone checks the chain of the server key itself.** A phone (a member's lane signature, the owner's wrap of the server line key, the re-attachment at a reset) acts for a server key only when the verified key log shows its registration vouched for by an approved device of its owner, and, after an owner reset, the re-attachment by the owner's new phone. A reset the server hides still needs the re-attachment. In a circle the key's owner must be a circle admin or a circle admin must have approved the key.
- The built-in server device finds its anchor from the key log by itself if it missed the live move after a reset (a restart or a failed write in that window no longer leaves it stuck on the old phone).
- App compatibility: new features `server_attach` and `required_server` (0.26.27). A member on an older app in a circle that requires server processing sees "(update the app to keep sharing with this circle)" in the circle name and is listed as needing the new app on the owner's screen; the join text tells a new member that the phone switches over by itself.
- The Server processing screen no longer promises to retry by itself, and when the settings cannot be confirmed it says "Not confirmed right now" instead of showing the last remembered state as current.
- Database migration 000410 (adds `e2ee_server_attach`, follows the attach in `e2ee_device_approved`, adds `e2ee_member_catching_up` and `circles.e2ee_server_gen_at` for the 72 hour catch-up of `e2ee_item_guard`); it has a down file.

- **Your encryption key survives reinstalling the app.** Deleting Orbitly used to delete this phone's key for Private circles, so after a reinstall you had to reset your keys and everyone had to approve you again. Now a sealed copy of the phone's own key is kept outside the app (Android: Google Play services Block Store, which also stores it end-to-end encrypted in your Google account when the phone has a screen lock; iPhone: the keychain, carried by an encrypted iPhone backup, never synced to iCloud Keychain). When you install again and sign in to the same account, the key comes back by itself, with the same safety number and no approval. It only comes back when the server still lists that key as active; after **Reset my keys** or a revoked key, a new key is made as before. If the copy cannot be read for a moment, the app does not make a new key over it; it asks you to try again. **Set this phone up again** (for a key that cannot be read) keeps the copy, so the same key can come back. Trade-off: Google (or your iPhone backup) holds an encrypted copy of that one key; a restored new phone shares the key with the old one until you revoke the old one. Turn it off in **Settings, Security, Keep this phone's key safe through reinstalls** (this deletes the copy). Not yet tested on a real phone. See [Reinstalling Orbitly](user/reinstalling.md).

## v0.26.26 (2026-11-10)

App-only release (the server needs no change; v0.26.25 fixed the database connections and needs a server update). Install over the current app.

- **Fixed: a stuck secure-storage place could cost the phone its sign-in.** The server logs showed a refresh that succeeded on the server at 01:05:42 while the phone never used the new token and presented the old one 14 minutes later, which signed the session out. On a phone whose Keystore storage hangs, saving the new token stopped at the stuck place and the reliable plain-file copy was never written. The app now writes the plain file first, bounds every Keystore call with a time limit, and finds the tokens it replaced afterwards. Reading is bounded the same way.
- **The Diagnostics report names why encryption failed.** The "Private circle delivery" section now shows a short reason after the code (for example `seal_unreadable:empty user id`), with all ids masked, and repeated sign-outs are logged once a minute instead of 40 times, so the last 50 events keep the useful lines.

## v0.26.25 (2026-11-10)

Server only: update the server, no app update needed.

- **Fixed: the server ran out of database connections under load.** The database image limited itself to 25 connections, which was fewer than the server's own pool (also 25) and left nothing for backups and admin tools. When many phones sent at once, requests were refused with "too many clients" or hung, which shows up in the app as a lost reply, a "Something went wrong" screen, a refresh that times out and, in the end, a sign-out. The compose file now sets the database limit to 60 (`PG_MAX_CONNECTIONS`) and the server's pool to 15 (`DB_MAX_CONNS`). Update the server and restart the stack (the database restarts for a few seconds).

## v0.26.24 (2026-11-10)

Server only: update the server, no app update needed.

- **Sign-in renewal: no second copy of a session past the retry limit.** A used sign-in token is answered again at most 8 times (v0.26.23). After that the old one-off grace, which would have created a second live copy of the session, is closed too: the token counts as reuse and the session is signed out.

## v0.26.23 (2026-11-10)

Update the server first, then the phones.

- **Fixed: being signed out again and again.** The server log showed the cause: when a phone is frozen or loses its connection while the app renews its sign-in, the server completes the renewal but the answer never arrives, so the app retries the same token about every 15 seconds. The server tolerated only one retry, and the third one looked like token theft and signed the whole session out (seen five times, on carrier data and on home Wi-Fi). The server now answers every retry of that token for 3 minutes with the same new token, with no extra copies and no sign-out. A retry after the new token was already used, or after the 3 minutes, is still treated as theft. To keep the wider window safe, one used token is answered again at most 8 times, and every repeat answer is written to the audit log as `auth.refresh_retry`, so a replay by someone else would be visible. Server change (migration 400 adds a small counter column): update the server for this one.
- **A phone in a Private circle can no longer stop sending its position without a word.** Several ways it could go quiet while still looking alive (its regular check-ins kept arriving) are closed:
  - Encrypting a position and uploading the encrypted queue each run one at a time. If one step never finished (for example a call to the phone's key store that never answered in the background), every later position waited behind it until the phone restarted: nothing was encrypted, nothing was sent and no error was recorded. Each step now gives up after a time limit, notes why, and the next position goes through.
  - The background service kept the phone's upload key from the moment it started. After signing in again, which gives the phone a new upload key and voids the old one, its encrypted uploads were refused with "not signed in" and kept for later, forever. It now reads the current key before every upload.
  - A background service that had not yet received a position (a phone lying still after a restart or a sign-in) never sent what was already waiting. Its regular check-in now sends the queue too.
  - A left-over "consent required" state from an earlier circle setting no longer stops the phone from encrypting, as long as the circle's current, verified setting lets members choose. While the circle really requires server processing and you have not agreed, nothing is sent, as before, and the report now says so.
- **The Diagnostics report has a new "Private circle delivery" section.** It shows how positions are sent (encrypted only, or both), and for each Private circle: whether it goes through the phone or the server (and which server key generation), how many updates are waiting, how many positions are waiting for a key, how long ago the last one was encrypted, how long ago the server last accepted an upload, and the last problem as a short code with its time (for example `http_401` or `seal_timeout`). It warns when the phone has fresh positions but has not encrypted one for half an hour. It holds counts, times and codes only: no places, positions, names or ids. The admin Fleet health page does not show it yet (that needs a server update).

## v0.26.22 (2026-11-10)

Server only: update the server, no app update needed.

- **The server now says why it refuses an encrypted upload.** Until now a phone whose position uploads were rejected looked the same as a phone that sent nothing. The server log now has one line per refused batch with the reasons and counts (for example `e2ee items rejected ... rejected=map[lane_not_server:12]`), and a line when a whole device is refused (revoked, read-only or not approved in the circle). The log carries short ids only, never positions or content.

## v0.26.21 (2026-11-09)

App-only release (the server needs no change). Install over the current app.

- **Your phone keeps reporting in the background even when its sign-in has lapsed.** Until now, when the app lost its sign-in (the server refused the session), it also stopped the background service and deleted the phone's upload key, so your position stopped reaching the family until you opened the app and signed in again. That is why opening the app while driving could show you still at work. Now a lapsed sign-in leaves the background service and its device key in place and the phone keeps sending positions; the app only asks you to sign in. Only an explicit **Sign out** removes the device key. If a different person signs in on the same phone, nothing of the previous account is kept.
- **Arrival and check-in notifications follow "Show names in notifications", and always name the place.** With names off they read "A family member arrived at Home"; with names on, "Henry arrived at Home". An empty place name now falls back to "a place" instead of leaving the text blank.
- **Arrivals, departures and check-ins (including SOS) reach every member of a Private circle.** If the person who made them uses server processing, they were sealed under the server's key, which other members' phones cannot open, so those members never got the notification. They are now sealed under the circle key every member holds, like chat and places. The server only uses location points and history, so nothing it relied on changed. Everyone in the circle needs this version to receive them.

## v0.26.20 (2026-11-09)

App-only release (the server needs no change). Install over the current app.

- **Fixed: still being signed out on a phone whose secure storage is stuck.** The Diagnostics report showed what was left: on this phone one storage place kept an old sign-in token and ignored deletes, another was always empty, and the only reliable copy was a plain file that each background process kept in its own memory. A second process could then offer a token that was already used, and the server signed the whole session out. The app now re-reads that file before every read, never offers or counts a token it knows was used (even if a stuck store still holds it), and remembers every token it held at sign-out. If you are signed out once more after updating, sign in again once; it should then hold.

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

## v0.26.18 (2026-11-09)

App-only release (the server needs no change). Install over the current app.

- **Fixed: being signed out after an app update.** The server logs showed the cause: after an update the app offered an older, already used copy of its sign-in token before the live one, and the server read that as token theft and signed the whole session out (token ages of 4 hours matched your sign-outs). The app now remembers every sign-in token it has used or replaced, across restarts, and never offers one again. Older copies left in any of its storage places are ignored. If you still get signed out, open Settings, Diagnostics and share the lines that mention `signout` or `spent`; they say why.

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
