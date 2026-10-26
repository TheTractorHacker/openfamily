# Live tracking: the sending side (phone)

Backend contract: `docs/live-tracking.md` (in the live-backend change). This
page describes how the phone decides how often to read the GPS and post
`POST /locations`, so a driving member's pin moves about once a second
(Life360-style) while a parked phone stays as cheap as before.

Code:

| File | Role |
| --- | --- |
| `app/lib/services/tracking_cadence.dart` | Pure policy (`TrackingCadence`, `CadenceConfig`, `ProfileApplier`) |
| `app/lib/services/fix_quality.dart` | Bad-fix filter, `speed_mps` / `speed_accuracy` fields |
| `app/lib/services/live_boost.dart` | `live_boost` command + `"live": true` parsing, cross-isolate boost + foreground-presence markers |
| `app/lib/services/location_reporter.dart` | Foreground reporter (map screen alive) |
| `app/lib/services/background_location_service.dart` | Background locator isolate |
| `app/packages/background_locator_2` | Vendored plugin; new `updateLocationRequest` call |

## Policy table

Inputs: smoothed GPS speed, activity-recognition motion state, live boost,
SOS burst, battery, foreground vs background. Precedence: SOS > boost >
driving > walking > stationary.

| Tier | Entered when | GPS request | Post gate (min between POSTs) |
| --- | --- | --- | --- |
| stationary, foreground | default | stream, `distanceFilter` 10 m | 5 s |
| stationary, background | default | interval 60 s, filter 0 (native drops to the 15 min STILL profile when activity recognition says still, liveness alarm unchanged) | 10 s |
| walking | smoothed speed >= 0.8 m/s, or motion state walking/running/cycling/driving | 5 s, filter 0 | 5 s |
| driving | smoothed speed >= 3 m/s for 2 consecutive fixes, or one fix >= 8 m/s | 1 s, filter 0 | 850 ms (GPS request is 1 Hz, so never above 1 Hz) |
| boosted | `live_boost` command or `"live": true` response | 1 s, filter 0 | 850 ms |
| SOS | SOS burst (5 min) | 2 s, filter 0 | 2 s (unchanged from before) |

Exits (hysteresis):

- driving ends after smoothed speed stays below 1 m/s for 60 s (red lights and
  traffic keep drive mode; speeds between 1 and 3 m/s never end it);
- walking ends after 30 s with speed below 0.4 m/s and no moving motion state;
- boost ends at its TTL (capped at 120 s); each `"live": true` response
  extends it by 10 s;
- no fix for 120 s resets the speed history and returns to the slow profile.

Low battery: below 15 % and not charging, and not boosted / SOS: walking
becomes 15 s and driving 5 s. Stationary is unchanged.

All numbers are constants in `CadenceConfig`.

## Applying the profile

- Foreground: `LocationReporter` re-opens the geolocator stream (interval via
  `AndroidSettings.intervalDuration`, `distanceFilter`) when the GPS part of the
  profile changes. A 5 s timer re-evaluates so a boost/SOS expiry or a
  drive-mode exit is applied even when the distance-filtered stream is silent.
- Background: the isolate calls the new native
  `BackgroundLocator.updateLocationRequest(intervalMs, distanceFilter,
  highAccuracy)`, which re-requests location updates inside the running
  foreground service (no service restart). Fast requests (<= 10 s) always run
  as requested; slow requests keep the native STILL low-power profile when
  activity recognition says the device is still. If the call is unavailable
  (older native build) the isolate falls back to a full re-registration.
- Debounce: a GPS-request change is applied at most every 20 s
  (`minApplyGap`). Speeding up for boost or SOS bypasses the debounce. A
  non-stationary profile is re-sent every 5 min in case native state was reset.
- The service keeps using the existing foreground notification while driving.

## Not piling up requests

One POST in flight per reporter. A fix arriving meanwhile becomes the single
pending fix; the pending fix it replaces is written to `LocationOutbox` and
ships through `POST /locations/batch` (drains are throttled to every 10 s).
While the app is open and its own reporter is alive (it marks a shared
timestamp every 5 s), the background isolate skips fast-tier posts so the
backend does not receive two 1 Hz streams.

## Fix quality and speed

Before sending, fixes are dropped when: timestamp is not newer than the last
accepted / sent one; accuracy > 50 m while moving (> 1 m/s); or the jump from
the previous accepted fix implies > 70 m/s (after 3 consecutive such fixes the
new position becomes the baseline, e.g. tunnel exit).

`speed_mps` is the receiver's speed, including `0` when the GPS says 0 and
horizontal accuracy is <= 30 m (0 with worse accuracy may mean "no speed" and
is omitted). `speed_accuracy` (m/s) is sent when the platform reports a
positive value. Speeds above 120 m/s are dropped.

## Live boost

- Direct push command `{"type":"live_boost","ttl_s":60}` is handled in
  `DirectPushDispatcher` (either isolate; the deadline is also persisted in
  shared preferences so the other isolate picks it up within ~5 s).
  Missing / invalid `ttl_s` defaults to 60 s; the TTL is capped at 120 s.
- `POST /locations` responses with `"live": true` keep the boost alive.
- Viewer side: `ApiClient.watchMember(userId, {circleId})` and the no-throw
  `ApiClient.watchMemberQuiet` call `POST /locations/watch` (the map should
  call it about every 15 s while a member is on screen).
- Coordinates are never logged.

## Diagnostics

The Performance screen's "Copy report" includes a `location reporting:` line
with the active cadence profile and fixes sent (this / last minute). Only the
foreground reporter reports there; the background isolate has no UI.

## Tuning / battery notes

Driving at 1 Hz costs noticeably more battery than the previous 60 s
cadence, but only while speed >= 3 m/s or someone is watching. The outbox holds
720 points (12 minutes at 1 Hz) if the phone is offline while driving.
