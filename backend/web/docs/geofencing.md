# Geofence alert thresholds

Arrival and departure alerts are evaluated server-side after each stored fix
(`handlers/geofence_eval.go`). Two layers keep GPS drift from raising false
alerts:

1. **Accuracy gate.** A fix whose reported horizontal accuracy is worse than
   `geofenceMaxAccuracyMeters` (100 m) is stored and shown on the map but never
   drives a transition (no enter, no exit, no pending transition). A fix with no
   accuracy value is trusted. The periodic reconcile pass applies the same gate
   to the last known position.
2. **Debounce.** A transition is notified at most once per
   `geofenceDebounceInterval` (60 s) per geofence and user. A transition inside
   the window becomes *pending*; if the user is back in the previously notified
   state before it fires, the pair is dropped, otherwise it fires once the window
   elapses (reconcile runs every 60 s).

Stationary jitter additionally dedups at ingest (`stationaryDedupMeters`
10 m, widened to 25 m for poor-accuracy fixes) so a parked phone does not write
rows or flip state.

Tests: `TestGeofenceFixUsable`, `TestGeofenceNoAlertOnLowAccuracyDrift`
(a low-accuracy drift burst produces zero events, one accurate departure
produces exactly one).
