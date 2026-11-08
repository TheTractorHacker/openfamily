# Watch apps (companion model)

The phone holds all secrets and sends watches a small readable snapshot; watches send back a fixed set of commands.

Status: Wear OS part implemented in v0.25 (unreleased). The Apple Watch part is
written by the Apple Watch workstream and is kept in its own section at the end;
the snapshot and command contract below is shared so both watches speak the same
language to the phone.

## Decision: the phone is the only holder of secrets

Orbitly's watches are **companions**. The phone app stays the only place that
holds the sign-in token, the Private-circle (end-to-end) keys and the server
address. It pushes a small, already-readable **snapshot** to the watch. The watch
sends **commands** back ("I'm OK", SOS, pause sharing). The phone runs them with
its own credentials and keys.

Why:

- **Private circles keep working.** Positions in a Private circle can only be
  decrypted on a phone that holds the circle key. A watch that talked to the
  server directly would need that key too (a new device to approve, a new key
  wrap, a new thing to lose). With the companion model no key or token ever
  exists on the watch.
- **No new server surface.** The server, API and migrations do not change. The
  watch is not a "device" in the server's eyes.
- **Battery.** The watch does no networking and no polling. It wakes only when
  the phone changes the snapshot.

Trade-off (said plainly in the user docs): the watch is only as live as its
phone. If the phone is off, out of Bluetooth/Wi-Fi range, or Orbitly is not
running on it, the watch shows the **last snapshot with its age** and a "phone
not connected" note, and commands cannot be delivered. A watch with its own LTE
cannot work alone (see "Standalone LTE mode" below).

```
 server <--TLS--> PHONE (tokens, E2EE keys, decrypts) <--Bluetooth/Wi-Fi--> WATCH
                      |  snapshot (JSON, < 100 KB)  --------------------->  (no secrets)
                      |  <------------------------- command (small JSON)
```

## Security

- **Pairing is the trust boundary.** On Wear OS the Wearable Data Layer only
  delivers data between a phone and the watch it is paired to, and only between
  apps with the **same applicationId signed with the same key**. The watch app
  uses `app.openfamily` (like the phone app) and the same release signing key
  (CI uses the same keystore secrets). A different app, or a differently signed
  build, cannot read the snapshot or send commands.
- **The watch trusts only its paired phone.** The watch app never opens a
  network connection and does not request `INTERNET`.
- **Commands are a fixed vocabulary.** The phone accepts only the commands listed
  below, with size limits, a replay window and per-command rate limits. Chat
  quick replies are sent as an **id** ("omw"); the phone maps the id to the
  text, so the watch cannot make the phone send arbitrary text.
- **SOS** from the watch needs a deliberate press-and-hold plus a 5 second
  countdown with cancel. The phone additionally refuses a second SOS within 60 s.
  Orbitly never contacts emergency services; the watch says so.
- **What leaves the phone.** The snapshot contains names, last positions
  (lat/lon), place names, addresses, battery, and alert text for the circle the
  phone currently shows. **For a Private circle that is plaintext on the
  phone-watch link and on the watch's storage**, but it never goes to the server
  or any third party by Orbitly. On Wear OS the Data Layer transfer goes over
  the local Bluetooth/Wi-Fi link between the paired devices; Google Play
  services on the phone and the watch handle it (Google's servers are not used
  for the transfer, but the Data Layer is a Google component, which is the
  accepted trade-off). Users who do not want plaintext of a Private circle on a
  watch can turn the watch bridge off in Settings, Watch (Private circles can
  also be excluded: "Show Private circles on the watch", default on, off removes
  them from the snapshot).
- Sign-out on the phone, or turning the bridge off, **deletes the Data Layer
  item** and is a *debt, not a best effort*: a persistent clear-pending flag (in
  Dart preferences and in native preferences) is set first. The clear counts as
  paid only when the delete succeeded and a watch was connected to receive it.
  Otherwise the flag stays, no snapshot is published (Dart refuses, and the
  native `publish` refuses) until the user signs in again, and the debt is paid
  the next time a watch connects (the watch app's `orbitly_watch_app`
  capability appears: `WatchListenerService.onCapabilityChanged`, which also
  works with the app closed, and a runtime `CapabilityClient` listener while it
  runs) or at the next app start. Just before sending, the bridge re-checks enabled, signed in and
  not-pending, so a snapshot being built during a sign-out cannot override the
  clear. On the watch, a deleted item, an empty (`signedIn: false`) snapshot, or
  a connected phone with no snapshot item at all wipes the stored snapshot and
  redraws the tile and complication empty.
- Dim/ambient: the watch app shows names and places in ambient mode, same as the
  Wear OS system does for other apps; no extra privacy layer is added.

## Snapshot (phone to watch)

One JSON document, UTF-8, `v: 1`. Hard cap 100 KB (the phone drops the least
important members until it fits; in practice it is about 3 to 6 KB for a family).

```json
{
  "v": 1,
  "ts": 1767225600000,
  "signedIn": true,
  "scope": {"id": "all", "name": "Everyone", "private": false},
  "circles": [{"id": "c1", "name": "Family", "unread": 2, "private": false}],
  "me": {"sharing": "on", "pausedUntil": null},
  "unread": 2,
  "members": [{
    "id": "u1", "name": "Sam", "initials": "S", "color": 4283215696,
    "lat": 51.5, "lon": -0.12, "fixAt": 1767225500000,
    "battery": 63, "state": "driving", "speedKmh": 68,
    "place": "Home", "address": "12 High St", "line": "Driving 40 mph",
    "private": false, "you": false
  }, {
    "id": "u2", "name": "Ana", "state": "still", "line": "Left Work",
    "lineAt": 1767224100000, "...": "..."
  }],
  "alerts": [{"id": "a1", "kind": "sos", "from": "Sam", "at": 1767225000000,
              "note": "", "active": true}],
  "lastCommand": {"id": "k9", "cmd": "checkin", "ok": true, "at": 1767225590000,
                  "message": ""}
}
```

- `state` is one of `driving`, `moving`, `at_place`, `still`, `stopped`, `none`.
- `line` is the phone's own one-line status text, so the watch and the phone
  always say the same thing (units follow the phone's setting), **minus anything
  that changes by itself as time passes**: the driving speed is rounded to 5 mph,
  and a relative time is split off into `lineAt` (epoch ms). The watch shows
  `line + " " + age(lineAt)` ("Left Work 25 min ago", "Updates stopped, last
  seen 3 d ago"), counting the age on its own clock. A watch app that does not
  know `lineAt` shows the line alone. Ages are worded `just now`, `N min ago`,
  `N h ago`, `N d ago` on both watches (shared vectors in the Kotlin and Dart
  tests).
- `ts` is when the snapshot was built; the watch shows "updated N min ago" from
  it. Members carry their own `fixAt` (when the position was taken).
- `lastCommand` is how the phone answers a command; a watch matches `id` with the
  command it sent. This avoids a second channel and is delta-friendly.
- The Apple Watch uses the same JSON (WatchConnectivity `applicationContext`).

Positions are rounded to 5 decimals (about 1 m). Members are capped at 15.

## Cadence

Every snapshot wakes the watch, rewrites its stored copy and may redraw the
tile and complication, so the phone sends only what the watch needs, at the
pace the watch asked for. All of it lives in the shared Dart bridge
(`watch_snapshot.dart`, `watch_bridge.dart`), so Wear OS and the Apple Watch
behave the same.

**Nothing in the snapshot ticks by itself.** The content hash is the snapshot
without `ts`, and nothing else in it changes as time passes: ages are formatted
on the watch from `fixAt`, `lineAt` and the alert `at`. A minute passing never
produces a snapshot.

**What changed decides how soon it goes out** (`classifyWatchChange`, compared
with the last snapshot the watch actually got):

| Change | Examples | Sent | Urgent |
|---|---|---|---|
| urgent | an alert arrived or ended; the answer to a watch command; first snapshot after sign-in, app start or a watch (re)connecting | within the 5 s floor | yes |
| event | unread count, sharing paused or resumed | within the 5 s floor | only if the watch app is on screen |
| meaningful | someone moved more than 100 m from where the watch last saw them, changed state (driving, at a place, stopped), place, status text or battery step (5% at 20% and below, 10% above), joined or left; circles or scope changed | at the tier's pace (below) | only if the watch app is on screen |
| minor | GPS jitter under 100 m, a newer fix time, a driving speed step | with the next keep-alive, or within 5 s while the app is on screen | as the tier |
| none | identical apart from `ts` | never | |

**Tiers: the watch says whether it is on screen.** The watch app sends
`visible` when it comes on screen and every 60 s while it stays there,
`visible` with arg `ambient` when it goes into always-on mode, and `hidden`
when it leaves. A `visible` not repeated within 150 s (an `ambient` within
15 min) expires by itself, so a lost `hidden` costs nothing.

| Tier | Meaningful changes | Keep-alive | Data Layer |
|---|---|---|---|
| visible | every change, at most one snapshot per 5 s; a fresh one right away when the app comes on screen | 60 s (keeps "Updated" current) | urgent |
| ambient | at most once per 60 s | 10 min | urgent |
| hidden (default) | at most once per 2 min | 10 min | not urgent: the system may batch it for a few minutes |

The roster is looked at no more than once per 5 s whatever the tier. Pushed
changes (alerts, unread, sharing) skip that floor.

**Measured** in `app/test/services/watch/watch_cadence_test.dart` (one simulated
hour, deterministic data; before = the same hour through the previous logic;
the two urgent ones in the quiet hours are the start-up snapshot and the first
roster after it):

| Hour | Before | After (hidden) | Urgent after |
|---|---|---|---|
| one person driving at 1 Hz | 720, all urgent | 31 | 2 |
| still family with GPS jitter | 125, all urgent | 7 | 2 |
| still family plus 4 alerts, 20 chat messages, a pause | 125, all urgent | 31 | 7 |
| one person driving, watch app on screen | 720 | 721 | all |
| one person driving, watch app in always-on | 720 | 61 | all |

**No polling for the watch.** Alerts and the pause state used to be fetched
over REST every minute while a watch was connected (about 126 requests an
hour). They are now fetched once and again only when the live socket reports
an alert or acknowledgement, the socket reconnects, or this phone pauses or
resumes, with a 10-minute safety refresh: 18 requests an hour.

**Link state.** The Wear app advertises the capability `orbitly_watch_app`
(`wear/app/src/main/res/values/wear.xml`). The phone listens for it with a
`CapabilityClient` listener while the app runs and through
`WatchListenerService` (manifest `CAPABILITY_CHANGED`, path
`/orbitly_watch_app`) while it does not; `status` counts reachable nodes with
the capability. A watch running an older Orbitly app does not advertise it:
then any connected watch counts as before, and its comings and goings are only
noticed by the 10-minute keep-alive re-check (the old peer callbacks needed the
deprecated `BIND_LISTENER`, which Android lint rejects). Not verified on a
device: whether `CAPABILITY_CHANGED` is delivered to the closed app on every
Wear OS and Play services version.

**On the watch (Wear OS).** An identical item is dropped with one string
comparison. The tile and complication are redrawn only when what they show
changed (`SurfaceGate`): signed in, unread, sharing or who has a position at
once; positions (about 100 m) and fix times (to the minute) at most once a
minute; battery, status text, alerts and keep-alives never. When the app leaves
the screen they are redrawn once with the latest data.

## Commands (watch to phone)

Wear OS: `MessageClient`, path `/orbitly/cmd`, payload a small JSON:
`{"id": "<random>", "cmd": "<name>", "at": <ms>, "arg": "<optional>"}`.

| `cmd` | arg | What the phone does |
|---|---|---|
| `sos` | none | Sends the same SOS as the in-app button (`POST /alerts/sos` with its own location, sealed position for Private circles). |
| `checkin` | none | "I'm OK" check-in to the circle (`POST /alerts/check-in`). |
| `pause` | minutes (15, 60, 240) | Pauses sharing for that time. |
| `resume` | none | Resumes sharing. |
| `ack` | alert id | Marks an alert seen (`POST /alerts/{id}/ack`). |
| `refresh` | none | Rebuilds and publishes the snapshot now (still rate limited to once per 5 s). |
| `reply` | reply id (`ok`, `omw`, `late`, `call`, `thanks`) | Sends the fixed text to the circle chat the phone has open (or the first circle). |
| `visible` | none, or `ambient` | The watch app is on screen (or in always-on mode): faster cadence (see Cadence). Never answered in `lastCommand`. |
| `hidden` | none | The watch app left the screen: back to the slow cadence. Never answered. |

The phone replies through `lastCommand` in the next snapshot. A command is
valid for 2 minutes after `at` (replay window; the watch and phone clocks only
need to agree to within that) and an `id` is processed once.

**When the phone app is not running.** Commands are handled by the Orbitly app
process. If the Flutter engine is not running the native receiver answers the
watch straight away with `ok: false` ("Open Orbitly on your phone") instead of
queueing: a stale SOS that fires minutes later would be worse than a clear
failure. The watch therefore always tells the user whether the command arrived,
and the SOS screen says "If it did not send, call emergency services".

## Wear OS app

- Separate Gradle project in `wear/` (Kotlin, Jetpack Compose for Wear OS,
  `androidx.wear.compose` Material), minSdk 30 (Wear OS 3+: Galaxy Watch 4 and
  newer, Pixel Watch, Fossil Gen 6, TicWatch Pro 5 and others). **Older Tizen
  Galaxy Watches (Watch 3 and earlier, Active, Gear) are not supported**: they
  are a different operating system.
- applicationId `app.openfamily`, versionName/versionCode computed from the
  release tag exactly as for the phone APK (`wear.yml` and `apk.yml` share the
  formula; locally the version is read from `app/pubspec.yaml`). The watch
  versionCode gets `+1` added to the phone's code only if Play requires
  distinct codes for the two form factors, which it does not for separate apps
  in one listing.
- `com.google.android.wearable.standalone` is **false**: the app needs the phone
  for all its data. Play then lists it as a companion-dependent watch app.
  Setting it to `true` would claim the watch works alone, which is not true in
  this design.
- Updates arrive by `DataClient` changes only (a `WearableListenerService` is
  woken by the system; the UI collects from a `StateFlow`). No polling, no
  background service, no wake locks. The only repeating message is `visible`
  once a minute while the app is on screen and not in ambient mode.
- Screens: People, Person (place, age, "Open on phone", distance and direction),
  SOS (hold to arm, 5 s countdown, cancel, haptics), I'm OK, Sharing pause and
  resume, Quick replies with unread badge, Alerts. A Tile ("Circle", the people
  nearest to you) and a Complication (nearest member, unread, sharing state).
- Distance and direction use the watch's last known location (only if the user
  grants location permission on the watch) and the member's coordinates; there
  is no map.
- Offline: the last snapshot is stored on the watch (DataClient item or a copy
  in app storage) and shown with its age; the header shows "Phone not connected".

### Phone side

`app/lib/services/watch/` (`watch_snapshot.dart` builds and hashes the snapshot,
`watch_bridge.dart` throttles and executes commands through injected actions)
and `WatchBridgePlugin.kt` (MethodChannel `app.openfamily/watch`,
`play-services-wearable`). Without Google Play services, or with no paired
watch, every call is a no-op and Settings, Watch shows "No watch connected".

## Standalone LTE mode (future work, not built)

A watch with a SIM could talk to the server itself. What it would need:

1. A token on the watch: a device-scoped refresh token minted by the phone ("link
   device", like the existing QR flow) so it can be revoked on its own.
2. For **Normal** circles this is straightforward (REST + WebSocket, or just
   polling every few minutes).
3. For **Private** circles it needs the circle key on the watch: the same
   approval flow as a new phone, a new key wrap per circle, and an encrypted
   key store on a device that has no secure lock in many cases. This is the
   real cost, and it breaks the "no key outside the phone" property.
4. Battery: LTE radios drain a watch quickly; it needs push (FCM) instead of a
   socket and a much slower location report cadence.
5. Play policy: a standalone watch app needs its own sign-in screen on a tiny
   keyboard, or a phone-assisted login.

Recommendation: ship the companion model first (this document), ask real users
whether the "phone out of range" case matters, and only then build standalone
mode for Normal circles, leaving Private circles companion-only.

## Apple Watch

Same companion model and the same JSON contract as above; details, the Xcode
project layout, CI and the kill switch are in [WATCH_APPS_APPLE.md](WATCH_APPS_APPLE.md).
**Status: written without a Mac, never compiled or run.**

- Watch app: SwiftUI, watchOS 9+, `app/ios/OrbitlyWatch/`, bundle id
  `app.openfamily.watchkitapp`, embedded in the iPhone app (`Runner.app/Watch/`).
- Transport (WatchConnectivity): the snapshot goes in `updateApplicationContext`
  (latest wins, no queue, no polling); a command goes in `sendMessage` as
  `{"json": "<the command JSON above>"}`. The iPhone answers the message only
  with "I have it"; the real result comes back as `lastCommand` in the next
  snapshot, exactly like Wear OS. If the phone is not reachable the watch says so
  and SOS is **never queued**.
- One Dart bridge for both: `watch_bridge.dart` drives `WatchBridgePlugin.kt` on
  Android and `app/ios/Runner/WatchBridge.swift` on iOS through the same
  MethodChannel `app.openfamily/watch` (`publish`, `clear`, `allowPublish`,
  `status`; callbacks `command`, `peerChanged`).
- Sign-out and switch-off are a debt on iOS too: the native side persists
  `blocked` (never send) and `clearUndelivered` (the wipe has not been handed to
  WatchConnectivity yet) separately, retries on every session event, and a new
  sign-in does not drop an undelivered wipe. Every context carries a session id
  generated by `allowPublish`; the watch drops stored data of any other session.
- Wear OS uses the same session idea: native `allowPublish` creates a NEW session id,
  every snapshot DataItem carries it next to the unchanged JSON (`json` and `session`
  keys), and the watch wipes the stored snapshot, tile and complication data before
  accepting an item whose session differs from the one it holds. `allowPublish` also
  tries to deliver an undelivered wipe first; the pending flag is dropped only when the
  delete succeeded with a watch connected (an empty snapshot announcing the new session
  is added when the app is not running).
- Not on the watch (v1): complications (needs a widget extension and App Group),
  live compass heading (the arrow is north-up from the coordinates in the
  snapshot), standalone LTE (see above).
