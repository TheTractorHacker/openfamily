# Driving events and the weekly driving report

OpenFamily detects three kinds of driving risk events on the server, from the
GPS fixes that already make up a trip, and summarises them per week or month
for the people in a circle.

| Kind | Meaning | Magnitude |
|------|---------|-----------|
| `speeding` | Speed above the limit for a sustained time | max speed, m/s |
| `hard_brake` | Sudden deceleration while moving | m/s^2 (positive) |
| `rapid_accel` | Sudden acceleration to a moving speed | m/s^2 |
| `phone_use` | Reserved. Never detected; shown as `null` in reports | - |

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
- `GET /trips/{id}/events` lists a trip's events. `GET /trips/{id}` includes
  the same list as `events`.

## Accuracy limits

These are estimates from phone GPS, not measurements, and not for enforcement.

- **Sparse GPS under-counts.** Phones often report a fix every 10-60 s to save
  battery. Acceleration is only computed between fixes at most 4 s apart, so a
  hard brake between two sparse fixes is invisible. Speeding is more robust.
- GPS speed is smoothed and noisy; occasional false events and missed events
  are expected. Tunnels, urban canyons and poor accuracy reduce quality.
- A passenger in a car is indistinguishable from a driver.
- An on-device motion sensor (accelerometer / gyroscope) and phone-use
  detection are a later phase; `phone_use` is reserved until then.

## Privacy

Events carry a time and a location, so they are as sensitive as trips. A
viewer sees a member's events (and counts in the report) only when they share
a circle with that member AND the member shares their location in that circle.
Outsiders and members with sharing off get 404 and are left out of the report;
a member always sees their own events. Events are deleted with their trip and
with the user, and old trips (and their events) are pruned after
`LOCATION_RETENTION_DAYS`.
