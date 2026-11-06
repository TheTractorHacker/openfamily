# Physical-device test procedures

Emulators cannot prove background tracking, doze behaviour, OEM battery
killers or real GPS. This document is the procedure; results go in the table
at the end.

> **Status: procedures written; physical execution BLOCKED.** No agent has
> access to physical phones. Every result row below is "not run" until a human
> fills it in. Nothing in this document is a measured result.

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
