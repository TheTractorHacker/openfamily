# Live tracking: the viewer side (smooth map, follow, speed)

Counterpart of `docs/live-tracking.md` (backend and reporter contract). This
page covers what the map does with the fixes it receives. None of it could be
run on a device while writing it; the unit and widget tests use a fake clock.

## Why it used to look jumpy

A pin jumped to every fix as it arrived (roughly every 2-10 s), the caption
rounded the speed to a whole mph from whatever the last roster said, and
tapping a member only animated the camera once. Now the pin is animated every
frame from a per-member track, the camera can lock onto it, and the speed is
the freshest GPS speed with a short low-pass.

## Pieces

| File | Role |
|---|---|
| `app/lib/services/marker_motion.dart` | Pure Dart per-member smoother (`MarkerMotion`, `TrackFix`, `MotionSample`, `MotionConfig`). |
| `app/lib/services/member_motion_hub.dart` | Owns one `MarkerMotion` per member; `frames` (per animation frame) and `speeds` (per fix) notifiers. |
| `app/lib/services/follow_camera.dart` | Locks the map camera to a member's display position, one `MapController.move` per frame. |
| `app/lib/services/watch_client.dart` | `POST /locations/watch` every 15 s while looking at someone. |
| `app/lib/screens/map_screen.dart` | One `Ticker`, the follow pill, marker layer. No `setState` per frame. |
| `app/lib/widgets/live_speed.dart` | `LiveSpeedBuilder`: rebuilds just a speed text per fix and on unit change. |

## How the smoother works

Time is always passed in (`DateTime now`), so it is deterministic in tests.

1. **Render about one fix behind.** When a fix arrives the pin eases from where
   it is drawn now to the fix over the fix-to-fix interval (the `ts` delta,
   clamped to 0.5-2.5 s, default 1 s). A steady 1 Hz drive becomes
   constant-velocity motion; chained segments are linear, a pin that was at
   rest eases out so it does not lurch.
2. **Coast when the next fix is late.** After the segment ends the pin keeps
   going along the heading at the GPS speed for up to 3 s (constant for 2 s,
   then tapering to a stop), then holds. Only when the speed is fresh and above
   0.5 m/s.
3. **Never backwards.** If a late fix lands behind the coasting pin, the pin
   holds until the track overtakes it.
4. **Snap, don't glide, on teleports:** a jump over 500 m, a gap over 2 min,
   or the first fix.
5. **Jitter rejection:** a stationary fix (speed < 0.5 m/s) within
   `max(accuracy, 8 m)` of the pin is ignored for position (speed, heading and
   time are still taken), so a parked pin does not wander.
6. **Out-of-order or duplicate fixes** (`ts` not newer than the newest) are
   dropped.
7. **Heading** (`heading_deg`, or the track bearing when absent) is trusted
   only while moving, held otherwise, and smoothed on the shortest arc with a
   0.25 s time constant (359 -> 1 turns 2 degrees, not 358).
8. **Speed:** the freshest `speed_mps`, 3-sample low-pass (rising: 75 % newest;
   falling: weighted mean 0.5/0.3/0.2). Exactly 0 below 0.5 m/s or when the fix
   is older than 15 s or was already old when first loaded. 0 is a value;
   null (no speed in the fix) shows as an em dash. Display uses
   `UnitPreferenceService.units` (mph or km/h). "Speeding" is
   `round(mph) >= 70`, i.e. the number on screen.

### Constants (`MotionConfig`)

`minSegmentS 0.5`, `maxSegmentS 2.5`, `defaultSegmentS 1.0`,
`deadReckonMaxS 3.0`, `teleportMeters 500`, `teleportGapS 120`,
`stationaryMps 0.5`, `stationaryMinRadiusM 8`, `headingTauS 0.25`,
`speedStaleS 15`, `maxPlausibleMps 90`.

## Frame cost

* One `Ticker` in `MapScreen`. It runs only while a pin or the follow glide
  needs frames and stops itself when everything has settled, so an idle map and
  a tab switch cost 0 frames and 0 rebuilds. The ticker is muted by
  `TickerMode` when the map tab or route is hidden.
* Each tick calls `MemberMotionHub.tick()`, which notifies only the marker
  layer; it `setState`s itself, not the screen.
* The marker layer reuses its cached bubbles and its clustering result. It
  re-clusters only when the roster, camera, expanded set or followed member
  change, or when a moving member drifted over 24 px since the last clustering.
* The followed member is never clustered.
* The speed caption inside a cached bubble listens to `hub.speeds` itself, so
  the bubble is not rebuilt when the number changes.
* `PerfMonitor` counters: `MarkerFrame` and `MapMarkerLayer` rebuilds (with
  "Record details" on) and `map animation frames`.
* Guards: `app/test/perf/live_motion_test.dart` (host never rebuilds, bubbles
  not rebuilt, clustering not per frame, idle = 0) and the existing
  `shell_tab_switch_test.dart` / `marker_layer_test.dart`.

## Follow mode

* Tapping a member marker or a People row centers on them and locks the camera
  to their display position every frame (`MapController.move`, no animation
  stacking). The first 450 ms glide eases onto the member; the zoom is kept
  unless it is below 14, then 16.
* Any user pan, pinch or fling (`hasGesture`) releases the lock. The pill
  "Following Name" stays with a recenter button (re-follow) and an X (stop).
  Tapping the name opens the member's details.
* Follow state lives in `MapScreen`'s state, so it survives rebuilds, the
  member leaving the viewport, and style/satellite toggles. It stops when the
  member goes offline (status stopped, no position, left the roster) or when
  the user uses Locate me or expands a cluster.
* While following (even if the user has panned away and the pill is showing),
  the app calls `POST /locations/watch` immediately and then every 15 s
  (server TTL is 45 s) so the target's phone reports at about 1 Hz. Calls stop
  when following ends, the app is backgrounded, or the map is hidden
  (`TickerMode`). Failures are silent: the target just keeps its normal
  cadence.

## Not done / needs a device

* Rotating the pin arrow to `heading_deg` while driving is not implemented
  (the smoothed heading is available as `MotionSample.headingDeg`).
* Real frame times, how it feels at 1 Hz over cellular, and the end-to-end
  watch boost with the reporter agent were not run on hardware.
