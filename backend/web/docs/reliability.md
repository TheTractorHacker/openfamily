# Reliability tools: diagnostics, silent-phone and late-arrival alerts, fleet health

Status: implemented and unit/DB-tested; **never run on a real phone** (see
`testing/PHYSICAL_DEVICES.md` for the one-hour run sheet that does that).

All of it is coordinate-free metadata (timestamps, counts, OS states), so it works
for Private (end-to-end encrypted) circles without the server learning anything new.

## In-app Diagnostics (Settings, Advanced, Diagnostics)

Runs on the phone and explains, in plain language, why it may not be reporting. Each
check is pass, warn, fail or info and most have a one-tap fix: location permission
level (always vs while in use), precise location, battery optimisation and background
restriction, vendor guidance and deep links (Xiaomi, Samsung, OnePlus, Huawei, Oppo; opened
through `DiagnosticsChannel.kt`), notifications, network, server reachability and
sign-in, last upload the server saw, upload queue size, push registration and last
delivery, clock skew against the server, background service, and for Private circles whether
the Keystore key opens. "Copy diagnostic report" produces a redacted text (no
coordinates, tokens or account details; a unit test enforces it).

Since 0.24.2 the Android Keystore wrapping key works while the phone is locked (iOS: after the
first unlock since boot), so Private-circle fixes are sealed and sent from a locked phone like any
other. Only a key that an older version created and that has not been re-wrapped yet (needs one
unlock with the app opened) makes fixes wait; Diagnostics then shows a warning, otherwise
"Keys available while locked". See docs/design/E2EE.md for the threat-model change.

The **Self-test** screen exercises what can be automated: Keystore round trip, vault
write/read, channel crypto round trip with tamper detection, uploading one real fix and
confirming the server registered it (server clock, so a wrong phone clock cannot fake a
pass), a local notification plus a server push (`POST /me/diagnostics/test-push`, 6 per
hour), and a 5-minute background test that checks the server heard from the phone while
the app was away.

The app sends a coordinate-free self-report (`PUT /devices/{id}/diagnostics`) at most every
30 minutes when it comes to the foreground and whenever Diagnostics is opened.

## Server facts

- `GET /me/diagnostics`: the caller's devices (push registration and last push result, last
  seen, self-reported states), `last_report_at`, last WebSocket connect, circles with their
  silent-alert setting, and `server_time` for clock-skew measurement.
- `GET /api/admin/fleet` (platform admin): the same for every member; the admin panel shows it
  as **Fleet health**.
- Liveness is recorded in `member_report_state` (throttled to one write per user per minute)
  and `member_report_hours` (one row per user per UTC hour, pruned after 28 days). Encrypted
  items expire quickly, so this is what Private circles use.

## Silent-phone alerts (`silence.go`)

Per circle, off by default. A circle admin picks 2 to 72 hours (the app offers 4, 8, 12, 24, 48).
A member whose phone has not talked to the server for that long **and** who reported in this
same UTC hour on at least 3 of the last 14 days (with at least 3 active days) triggers one alert to
the circle admins and to the member. It is idempotent per silence episode
(`silence_alert_state`), stops after 7 days of silence, is held back when half the circle (3 or
more people) is silent at once (outage guard), sends at most 5 per circle per 10-minute pass, skips
recipients in quiet hours or with "Silent phone alerts" off or who muted that member (the episode
stays open so it can fire later), and honours per-member disable and snooze. Copy says
"A family member's phone" unless the recipient enabled names. Paused sharing members are skipped.

Limits: the "normal hours" model is by UTC hour of day, not the member's time zone; a member who
turns their phone off every night at the same hour is learned correctly only if that hour is
consistently silent.

## Quiet-phone wake-up (`stale_wake.go`, since 0.26.34)

A different job from the silence alert: it does not tell anybody, it asks the quiet phone to report. Every 5 minutes the
server looks for Android devices whose last report or heartbeat (`devices.last_seen`) is older than 30 minutes and
younger than 24 hours, and sends **that one device** the same `location_request` command a viewer's refresh sends
(direct channel and UnifiedPush, whichever it has). The phone answers with one fix, and its handler also asks the Android
tracking service to restart if tracking is wanted and the service is gone (Android may refuse that start from the
background; the phone's journal says so). Rules: only the member's newest Android device; only members sharing in a
live circle and not in a paused-sharing window; not iPhones; at most one ask per device per 15 minutes (one atomic
`UPDATE`, recorded in `devices.last_stale_wake_at` and `stale_wake_count`); after 8 unanswered asks in a row it stops until
the device reports again; at most 12 asks per device in any 24 hours, whether or not it answered; nothing when 5 or more devices and at least half of the active ones look quiet at once
(outage guard); at most 50 asks per pass. It is on whenever the server runs and has no setting yet.

Limits: a phone that is off, signed out or force-stopped (Samsung "Sleeping apps") cannot answer. The direct channel is a
connection held by the app, so it cannot wake a dead process; only a UnifiedPush endpoint can.

## Late-arrival alerts (`arrival.go`): minimal version

Opt-in per person and per saved place (Settings, Notification settings, Late-arrival alerts). Only for circles
whose positions the server can read (plain circles, or trusted-server Private circles); Private
circles are never evaluated and the API refuses to create a watch for them. Needs at least 5
arrivals over 42 days on the same kind of day (weekday or weekend, in the person's own offset), on
at least 60% of those days, with a median absolute deviation of 30 minutes or less. Alerts at the
median plus 60 minutes, for up to 3 hours after, only if the phone reported within 2 hours, the
person is not at the place and has not arrived today. Hard limits: one per person/place/day, two per
person per 24 hours, 20 per pass.

Not done: holidays and one-off schedule changes (the median adapts after a few days), per-place
thresholds, snooze (turn the toggle off), departure ("usually leaves by") alerts.
