# Push notifications

OpenFamily can deliver alerts (SOS, help, check-in, geofence arrivals) and
silent commands (location refresh requests) over three transports. A phone
never needs Google services, and on Android it no longer needs a second app.

| Transport | Platform | Needs | Reaches a phone that is... |
|---|---|---|---|
| **Direct** (built in) | Android | nothing; on by default | connected to your server (see limits below) |
| **UnifiedPush / ntfy** | Android | the ntfy app (or another distributor) and an ntfy server | dozing or with the app stopped, as long as the distributor is alive |
| **APNs** | iOS | an Apple developer account and a `.p8` key | anywhere Apple can reach |

The transports are independent. A device can use direct and UnifiedPush at the
same time; the server picks per device (below). ntfy/UnifiedPush stays
supported and is now optional.

## Direct channel

### How it works

1. On sign-in the app registers the device with `push_transport: "direct"`
   (`PATCH /devices/{id}`), and makes sure it holds a device ingest key.
2. While it is allowed to run, the app keeps **one** authenticated HTTPS
   connection open: `GET /push/stream` (Server-Sent Events), authenticated with
   `X-Device-Key: <device_id>.<ingest_key>`, the same credential the background
   location reporter uses. A bearer token plus `?device_id=` also works.
3. When an alert is created the server writes an event into the device's
   `push_outbox` row set and, if the device is connected, wakes its stream. The
   app shows a local notification and acknowledges the event with
   `POST /push/ack`.
4. A device that is offline keeps its events (bounded, with a TTL) and receives
   them the next time it connects.

Frames on the stream: `event: hello` (once), `event: push` (data is the
payload), `: hb` comment heartbeats every 55 seconds, and `event: bye` with a
`reason` (`revoked`, `closed` or `replaced`) before the server closes.

### Delivery guarantees

- **At least once.** An event stays queued until the device acknowledges it and
  is re-sent on every reconnect. The app deduplicates on the event id and
  derives the notification id from it, so a re-send replaces rather than stacks.
- **Queue limits.** Latest 50 undelivered events per device. TTLs: alerts 6 h,
  geofence notices 1 h, commands 5 min. Expired alert events are recorded as a
  failed delivery (`expired`) in the alert's delivery list.
- **Delivery state** (`alert_deliveries`, channel `push`): `queued` when stored,
  `sent` when written to the device's open stream, `delivered` when the device
  acknowledged it, `acknowledged` when the person confirmed the alert in the app
  (`POST /alerts/{id}/ack`, which also retires that alert's queued events on the
  user's other devices). `delivered` means the phone has the notification, not
  that someone read it.
- **Transport choice per device.** A direct device always gets the event queued.
  If it is not connected right now and also registered a UnifiedPush endpoint,
  the server additionally sends through UnifiedPush. A connected device gets
  direct only. Devices without direct behave exactly as before.

### Privacy

Payloads are built from the same title and body the UnifiedPush and APNs
senders use, so they never contain coordinates and carry no sender name or note
unless `VERBOSE_PUSH=true`. They only add the alert id (to open the right
screen) and a dedupe id. Events travel from your server to your phone only; no
third party sees them. The stream is plain TLS to your own origin. A test scans
direct payloads for coordinates and names.

### Authentication, limits and revocation

- Auth failures return 401. A device only streams for itself; a bearer token for
  another user's device gets 404.
- At most **8 simultaneous device streams per user**; more get 429. A second
  stream for the same device replaces the first (the old one receives
  `bye: replaced`).
- Connect attempts are rate limited per user.
- The server rechecks credentials every 20 seconds while a stream is open and
  closes it (`bye: revoked`) after logout, password change, ingest-key rotation
  or expiry, access-token expiry (bearer streams), and device deletion. Logout
  and device deletion also close it immediately.
- Behind Caddy the stream path is excluded from gzip and buffering (see
  `caddy/Caddyfile`). Other reverse proxies must disable response buffering for
  `/push/stream` and allow idle connections for a few minutes.

### Setup

Nothing, on a default install. `DIRECT_PUSH=false` in `.env` disables it
(`GET /config` then reports `direct_push: false` and apps skip registration).
Family members only need background location permission and, recommended, the
battery-optimization exemption that onboarding already asks for.

### Battery

The app holds a single TCP connection and the server sends one tiny heartbeat
every 55 seconds, so the radio wakes about once a minute while the connection
is up. The app treats 150 seconds of silence as a dead connection and
reconnects with exponential backoff (2 s doubling to 5 min, with jitter); a
network change (Wi-Fi to mobile, coming back online) reconnects at once.

- The connection is held **by the background location foreground service** (its
  isolate keeps it alive and revives it on every location fix and heartbeat), so
  no extra service or notification is added. Location reporting already keeps
  the device awake for fixes, which makes the marginal cost small but not zero.
- The foreground UI holds a connection only while the app is open and the
  location service is not running.
- If background location is not granted ("Allow all the time"), there is no
  foreground service and the connection exists only while the app is open.

### What happens when Android kills or freezes the process

The direct channel needs a live process. Honest limits:

- **Process killed** (swipe-away on some vendors, memory pressure, force stop):
  nothing can receive until the process runs again. Queued events then arrive
  the next time the location service or the app starts, within their TTL. An SOS
  is not lost, but it can be late.
- **Doze and OEM battery savers** can freeze the network for a foreground
  service on deeply idle devices. This is **weaker than FCM**, which uses a
  system-level connection that survives those states. Recommended mitigation:
  accept the battery-optimization exemption during setup (or set the app to
  "Unrestricted"/"Don't optimize"), and keep background location on.
- If that is not enough for a family member's phone, additionally install ntfy:
  with both configured, a disconnected phone is also reached through ntfy.

## UnifiedPush / ntfy (optional)

Unchanged: the device registers its distributor endpoint
(`unifiedpush_endpoint`) and the server POSTs the message to it. Set
`NTFY_BASE_URL` (and `PUSH_ADDRESS`/the `push` compose profile for the bundled
ntfy server, see `docs/self-hosting.md`). The server validates endpoints to
https and public addresses only. Use it for phones where the direct channel is
too fragile, or when you already run ntfy.

## APNs (iOS)

Set `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_TOPIC`. Alerts are
sent as visible pushes and location refreshes as silent `content-available`
pushes. The direct channel is Android only.

## API summary

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/push/stream` | device key or bearer + `device_id` | event stream |
| POST | `/push/ack` | same | `{"device_id","ids":[...]}`, up to 50, marks `delivered` |
| PATCH | `/devices/{id}` | bearer | `push_transport`: `"direct"` or `""` |
| POST | `/devices` | bearer | accepts `push_transport` at registration |

## Verification status

Server code is covered by table-driven and real-Postgres tests (queueing, ack,
dedupe, TTL, bounded queue, connection cap, auth failure, close on revocation,
payload contents). The Android client has unit tests with fakes (SSE parsing,
backoff, routing, reconnect logic). It has **not** been run on a physical device:
foreground-service behaviour, Doze behaviour and notification tap routing from
the background isolate still need on-device testing.

## Per-member notification settings

Each user can choose which alerts they get about each other member they share
a circle with: arrivals, departures, low battery, driving/speeding, mute-all,
and optional quiet hours (`GET/PUT/DELETE /members/{id}/notification-prefs`,
table `notification_prefs`). A user can only read and edit their own settings,
and only about members of circles they share (anything else is 404).

- Geofence arrival/departure pushes honour the settings when the event's
  device rows are created. A lookup error fails open (the push is sent).
- SOS, help and check-in alerts are never filtered, whatever the settings say:
  the filter only recognises the four optional categories.
- Low-battery and driving/speeding settings are stored and enforced by the same
  filter (`notifSuppressed`), but the server does not yet send push
  notifications for those events, so nothing consumes them today.
- Quiet hours use the phone's UTC offset (`UTC+05:30`) or an IANA zone; a
  fixed offset does not follow daylight saving until the app re-saves.
