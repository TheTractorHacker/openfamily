# Driving events and the weekly driving report

OpenFamily detects three kinds of driving risk events on the server, from the
GPS fixes that already make up a trip, and summarises them per week or month
for the people in a circle.

| Kind | Meaning | Magnitude |
|------|---------|-----------|
| `speeding` | Speed above the limit for a sustained time | max speed, m/s |
| `hard_brake` | Sudden deceleration while moving | m/s^2 (positive) |
| `rapid_accel` | Sudden acceleration to a moving speed | m/s^2 |
| `phone_use` | Phone handled while driving. Only from the phone (below), and only for members who turned on the separate phone-use opt-in; `null` in reports (shown as Off in the app, never 0) for everyone else | interaction duration, s |

Events only exist inside legs classified as `driving` (walking, cycling and
slow transit never produce events).

## How events are detected

Code: `backend/internal/trips/events.go` (pure functions, unit tested with
synthetic tracks). The fixes are cleaned first (out-of-order, duplicate,
inaccurate and teleporting fixes are dropped), then:

- **Speeding**: consecutive fixes whose speed is above the limit, at most 15 s
  apart, lasting at least the minimum duration (first to last over-limit
  fix). One event per sustained episode, with start, end and max speed.
- **Hard brake / rapid acceleration**: acceleration is computed only between
  two consecutive fixes at most 4 s apart (and at least 0.5 s), both with
  accuracy of 30 m or better, using the GPS speed (distance / time only when
  the device did not report a speed). Braking needs the vehicle above about
  5 m/s before the interval, acceleration needs it above 5 m/s after. Intervals
  implying more than 12 m/s^2 are GPS jumps and are ignored. Adjacent
  qualifying intervals of the same kind merge into one event.

Events are replaced together with their trip (same transaction), so
recomputing with `POST /trips/compute` is idempotent. New trips get events from
the background job; to add events to older trips, recompute the range.

## Thresholds

| Env | Default | Meaning |
|-----|---------|---------|
| `DRIVING_SPEEDING_MPS` | 35.76 | Speeding limit, m/s (80 mph) |
| `DRIVING_SPEEDING_SECONDS` | 30 | Minimum duration above the limit |
| `DRIVING_HARD_BRAKE_MPS2` | 3.5 | Deceleration magnitude of a hard brake |
| `DRIVING_RAPID_ACCEL_MPS2` | 3.5 | Acceleration of a rapid start |

Empty, non-numeric or zero values fall back to the defaults. The thresholds in
effect are returned in the report (`thresholds`). The older per-request
`speed_threshold_mps` of `GET /trips/summary` is independent and unchanged.

## API

- `GET /trips/report?period=week|month&start=YYYY-MM-DD&utc_offset_minutes=&circle_id=`
  Weeks start on Monday in the caller's local time (local date derived from
  `utc_offset_minutes`, default 0); `start` selects any week or month (snapped
  to its start). `circle_id` defaults to the caller's primary circle.
  Returns `totals`, `previous_totals`, per-member `events` and
  `previous_events`, `thresholds` and `estimated: true`. Members include
  everyone the viewer may see, also those with zero drives. Distances are in
  metres and speeds in m/s; clients convert.
  Also returns (additive):
  - `days`: one `{date:"YYYY-MM-DD", drives, distance_m, top_speed_mps}` per
    local calendar day of the period (7 for a week, 28-31 for a month), zero
    filled, with days cut at the caller's `utc_offset_minutes`.
  - `recent_trips`: up to 10 driving trips of the period across the visible
    members, newest first: `{id, user_id, name, started_at, ended_at,
    distance_m, duration_s, max_speed_mps, mode, event_counts:{speeding,
    hard_brake, rapid_accel, phone_use}}`. `event_counts.phone_use` is `null`
    unless that member has phone-use detection on. Event counts follow the same
    "sensor wins" view as the report.
  Both use exactly the report's authorization: circle membership plus the
  member sharing location (a member always sees their own trips).
- `GET /trips/{id}/events` lists a trip's events. `GET /trips/{id}` includes
  the same list as `events`.

## Phone sensor events

The Android app can detect `hard_brake` and `rapid_accel` with the motion
sensor, and `phone_use` (a separate, experimental switch that stays off by
default), and upload them. Driving detection is **on by default in the app**:
the app sends the opt-in (`sensor_enabled=true`) the first time it can and
retries until acknowledged; turn it off in Settings > Driving detection.
The opt-in is per user, not per device, and is stored in
`users.driving_sensor_enabled` (server default false until the app reports).
Phone-use detection has its own opt-in, `users.driving_phone_use_enabled`
(migration 000103, default false, requires the sensor opt-in), because the
server cannot know it from `sensor_enabled`.

### `POST /trips/sensor-events`

Authenticated exactly like `POST /locations`: `X-Device-Key: <device_id>.<key>`
(bound to its device and user; a body naming another `device_id` is 403) or a
normal Bearer access token. Body, at most 64 KB (413 above):

```json
{"events":[{"kind":"hard_brake","started_at":"2026-10-21T12:00:00Z",
            "ended_at":"2026-10-21T12:00:02Z","magnitude":4.2,
            "lat":40.1,"lon":-75.2}],
 "sensor_enabled": true, "phone_use_enabled": false}
```

- `kind`: `hard_brake`, `rapid_accel` or `phone_use`.
- `started_at` / `ended_at`: RFC3339; start within the last 7 days and at most
  5 minutes in the future; end not before start, duration at most 5 minutes.
- `magnitude`: m/s^2 in 0-30 for braking and acceleration; for `phone_use`
  the interaction duration in seconds, 0-300.
- `lat` / `lon`: both or neither (null), within -90..90 / -180..180.
- At most 100 events per request (400 above). `events` may be empty when
  `sensor_enabled` or `phone_use_enabled` is given. 30 requests per minute per device (429).
- `sensor_enabled` (optional) sets the opt-in. `false` turns the feature off:
  later events are not stored (counted as `rejected`) and existing ones are
  kept. Events are only stored while the opt-in is true, so the first upload
  should carry `"sensor_enabled": true`.
- `phone_use_enabled` (optional) sets the separate phone-use opt-in. When
  omitted the stored value is kept. `phone_use` events are accepted only while
  it is true (otherwise they count as `rejected`). Turning `sensor_enabled`
  off also forces phone use off, even if `phone_use_enabled: true` is sent in
  the same request; turning the sensor back on does not bring it back.

Response `200`: `{"accepted":n,"duplicate":n,"rejected":n,"sensor_enabled":bool,"phone_use_enabled":bool}`.
Events are deduplicated on (user, kind, started_at), so retrying a request is
safe. Invalid events are counted in `rejected`; the others are still stored.
The audit log records counts only.

### Linking and merging

- A sensor event is attached to the trip whose `[started_at, ended_at]`
  contains its start. If it arrives before the trip exists (or the trip is
  recomputed later) it stays unattached and is linked when the trip is stored.
  Unattached events still count in the report.
- Recomputing a trip (`POST /trips/compute`, the background job) replaces only
  `source = 'gps'` events; sensor events survive.
- **Sensor wins.** When a GPS-derived and a sensor event of the same user and
  kind overlap within +-4 s, only the sensor event is counted. GPS rows stay
  stored. The rule lives in one place, the SQL view `trip_events_effective`
  (migration 000101), which the report and the trip events query read.

### Report and trip changes

- `GET /trips/report` counts include sensor events. `phone_use` is a number
  only for members with the sensor AND phone-use opt-in enabled and `null`
  for everyone else (a member without phone-use detection never reads 0);
  `totals.events.phone_use` (and `previous_totals`) is the sum over those
  members, `null` if there are none. `sensor_members`: the user ids (of
  members the viewer can see) with the sensor enabled. `phone_use_members`:
  the user ids with phone-use detection enabled.
- **Compatibility.** Clients up to v0.6.0 never send `phone_use_enabled`, so
  their stored value stays false: their `phone_use` is `null` in reports and
  any `phone_use` events they upload are now rejected (they used to be
  counted). Updating the app sends the flag from the phone-use switch.
- Every event of `GET /trips/{id}/events` (and `GET /trips/{id}`) has `source`
  (`gps` or `sensor`); `lat` / `lon` are `null` for sensor events without a fix.

## Accuracy limits

These are estimates from phone GPS, not measurements, and not for enforcement.

- **Sparse GPS under-counts.** Phones often report a fix every 10-60 s to save
  battery. Acceleration is only computed between fixes at most 4 s apart, so a
  hard brake between two sparse fixes is invisible. Speeding is more robust.
- GPS speed is smoothed and noisy; occasional false events and missed events
  are expected. Tunnels, urban canyons and poor accuracy reduce quality.
- A passenger in a car is indistinguishable from a driver.
- Sensor events (below) are far more precise for braking and acceleration,
  but depend on the phone being in the car, mounted or not, and on the user
  having enabled the feature.

## Privacy

Events carry a time and a location, so they are as sensitive as trips. A
viewer sees a member's events (and counts in the report) only when they share
a circle with that member AND the member shares their location in that circle.
Outsiders and members with sharing off get 404 and are left out of the report;
a member always sees their own events. Events are deleted with the
user, included in `GET /me/export` (`driving_events`, `driving_sensor_enabled`,
`driving_phone_use_enabled`)
and pruned, including unattached sensor events, once older than
`LOCATION_RETENTION_DAYS`. Sensor events are read through the same circle
rules as trips.
