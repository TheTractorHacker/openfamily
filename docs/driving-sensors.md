# On-device driving events (motion sensors)

Part of issue #45. GPS-only braking detection (server side) under-counts
because a 1-60 s GPS cadence smooths a 1-2 s stop. When the user opts in, the
Android app also uses the phone's accelerometer and gyroscope while driving,
detects hard braking and rapid acceleration on the device and uploads **only
the detected events**.

## Privacy contract

* Opt-in, default OFF (Settings > Driving detection). The switch calls
  `POST /trips/sensor-events` with `sensor_enabled` and is stored locally
  (`driving_sensor_enabled`). Turning it off stops sampling at once, deletes the
  unsent queue and tells the server (`sensor_enabled=false` opts out there).
* Raw samples live in memory inside the detector (a 30 s ring buffer) and are
  never written to disk or sent. Uploaded: kind, start/end time, magnitude and
  the latest GPS position.
* Sensors run only inside a driving session (below).

## Pipeline (`app/lib/services/driving/`)

| File | Role |
| --- | --- |
| `motion_detector.dart` | Pure Dart detector (all maths, unit tested) |
| `driving_config.dart` | Thresholds, default 3.5 m/s^2, 400 ms, speed gate 5 m/s |
| `driving_session.dart` | GPS-speed state machine that gates the sensors |
| `driving_runtime.dart` | Glue: session -> feed -> detector -> outbox -> upload |
| `driving_platform_feed.dart` | `sensors_plus` + `driving_native` plugin |
| `driving_event_outbox.dart`, `driving_events_service.dart` | Queue, retry, batches |
| `phone_use_tracker.dart` | Screen activity while moving (estimate) |
| `driving_background.dart` | Hook called from the background isolate |

Detector steps: gravity estimate (low-pass, rotated with the gyroscope so real
braking does not leak into "gravity"), linear acceleration, projection onto the
horizontal plane, **forward axis learned from the car itself** (during GPS
speed changes >= 0.8 m/s^2 the mean horizontal acceleration is voted along the
sign of the speed change; the sum points forward; needs >= 3 votes and 0.7
coherence; dropped if the phone tilts > 25 degrees or is handled), signed forward
acceleration smoothed (150 ms), hysteresis episodes (>= threshold for >= 400 ms,
exit at 80 %, 150 ms gap tolerance), cross-check with the GPS speed change over
the event (sign and >= 40 % of the expected delta) and the speed gate (> 5 m/s
before or after), merge of same-kind events < 2 s apart. When the axis becomes
known the buffered history is replayed so the launch that taught the axis is
still evaluated. Ignored: potholes (short, mostly vertical), gyro spikes
> 1.5 rad/s, horizontal acceleration > 12 m/s^2, any deviation from the gravity
estimate > 8 m/s^2 (phone moved), episodes touching a handling event.

### Session / battery

The existing background location service delivers a fix about every 60 s. A fix
with speed >= 5 m/s arms a session: `sensors_plus` accelerometer and gyroscope
at 50 Hz, and a 1 Hz GPS stream (platform `LocationManager`, no Play Services).
The session is confirmed when speed stays >= 5 m/s for 10 s (else it stops
after 90 s) and ends after 120 s below 5 m/s; every subscription is cancelled
then, which unregisters the native listeners. Nothing samples while parked or
walking. Consequence of the 60 s cadence: **the first up to ~60 s of a trip
are not covered** (the first launch is usually missed).

## Android requirements

* No new permission. Accelerometer/gyroscope are not protected; 50 Hz is below
  the 200 Hz `HIGH_SAMPLING_RATE_SENSORS` limit; `ACTIVITY_RECOGNITION` is not
  needed for raw sensors (the existing entry is for the separate Play Services
  motion profile); the screen broadcasts need none; location is the existing
  background-location grant.
* Sensor events reach the app in the background only because the location
  foreground service (`IsolateHolderService`, type `location`) keeps the
  process alive. Without "Allow all the time" the service does not start and
  neither does detection.
* Plugin registration in the headless engine: the vendored locator creates
  `FlutterEngine(context)`, whose constructor auto-registers
  `GeneratedPluginRegistrant`, so `sensors_plus` and `driving_native` are
  available in the background isolate the same way `battery_plus` and secure
  storage already are.
* `sensors_plus` 7.1.1 registers a plain `SensorManager` listener without a
  max-report-latency, so hardware FIFO batching is not used. Acceptable
  because it only runs while driving; a native batched listener is a possible
  later optimisation.

## Phone use (`phone_use`), Android, estimate only

Implemented, default OFF (second switch, requires the first). The local plugin
`app/packages/driving_native` registers a receiver for `ACTION_SCREEN_ON`,
`ACTION_SCREEN_OFF` and `ACTION_USER_PRESENT` dynamically (they cannot be
manifest-declared) on the application context, only while a driving session is
running. Because it is registered in the headless engine hosted by the
foreground service, the process and receiver live as long as tracking does.
An interaction starts at an **unlock** while speed > 7 m/s and ends at
screen-off, when the vehicle stops, or after 120 s (shorter than 3 s ignored);
`magnitude` is the duration in seconds. A screen that is simply on (mounted
navigation) or woken by a notification without unlock is not counted. It cannot
tell a passenger from a driver or a navigation app from anything else, so it is
labelled "screen activity while moving". No UsageStats permission. The
accelerometer pick-up cue was not implemented.

## Not covered / known limits

* Android only; iOS has no equivalent here.
* Forward axis needs one clear acceleration or braking (about 3 s) after start
  or after the phone is moved; events before that are replayed from the buffer,
  but a phone repositioned mid-event may lose it.
* Pothole/handling rejection thresholds are conservative guesses that must be
  tuned with real drives.

## Field-test checklist (nothing here was run on a device)

1. Sensor rate in the background isolate (screen off, app swiped away): log
   the achieved Hz of accelerometer/gyro and GPS in a debug build.
2. Detection accuracy in a real car with phone in cup holder, mount, pocket,
   seat; compare against a reference (OBD or a second app).
3. False positives: potholes, speed bumps, pickup, dropping, passenger handling.
4. Battery drain on a one-hour drive and on a parked day (should be zero extra).
5. Screen events under Doze/app standby, and after the OS kills the process.
6. Devices without gyroscope; GPS Doppler speed absent; OEM background limits.
7. Opt-out: switch off mid-drive stops sampling within ~5 s and the server
   receives `sensor_enabled=false`.
