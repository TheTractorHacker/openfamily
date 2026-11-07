# Offline resilience: what Orbitly does when the server is down

Status: the cache, the store-and-forward queues, the reachability probe and the status chip are **implemented and unit tested**;
nothing here has been run on a real phone or a real flaky network (see section 9). The fallback relay (section 5b) is **not built**
and the reasons are written down below.

Owner request: *"If a server ever goes offline, the app is still functional, because no matter if it is end-to-end encryption or not,
we want people to be able to see one another. We can have it stored locally on their phones, and once it is ready, it can push out to their server."*

## 1. Short version

* The phone is the source of truth for **what it knows**. It remembers the last answer of the server (circles, people and their last
  positions, places, recent chat, notifications, trips) and shows it at once, with a small chip saying the server cannot be reached.
* Everything a person **does** while the server is out of reach (location fixes, check-ins, SOS and help alerts, chat messages) is
  saved on the phone and sent, in order and exactly once, when the server answers again.
* An SOS that cannot be delivered says so plainly ("SOS not sent yet"), keeps trying, and offers to open the phone's own messaging app
  with the emergency contacts and the last position, which needs no data connection and no Orbitly server.
* What cannot work without a server: **new positions of other people**. They are produced on other phones and only a server (or some
  relay) can carry them. Section 5 evaluates the options for that.

## 2. What users see and do not see when the server is down

| Thing | While the server is down |
| --- | --- |
| Opening the app | Opens straight to the map from the saved snapshot. It does not wait on the network for more than 4 seconds, and never signs anyone out because the network failed. |
| People on the map | Everyone's **last known** position, each with its real age ("last seen 3 h ago"), in normal and Private circles. No new movement of others. |
| Your own position | Keeps being recorded and queued (12 h / 720 fixes in normal circles, 48 h / 2000 items in Private ones; oldest fixes go first). They arrive in order afterwards, so history has no hole. |
| Places, circles, trips, notifications | The last copy. Creating or editing a place in a normal circle needs the server (Private circle places are local and work). |
| Chat | Reading: the newest messages of each circle. Writing: the message appears as "waiting to send", is stored on the phone and sent in order. Photos need the server. |
| Check-in, Help alert | Saved and shown as "Not sent yet"; sent automatically later, once. |
| SOS | "SOS not sent yet", retried in the background, SOS first in the queue, "Text my emergency contacts" through the phone's own SMS, "Call emergency services". Never dropped. |
| Settings | Last known values show. Changes that were made through the queue are replayed; some screens still need the server and say so. |
| Sign-in with a password, joining a circle by code, adding a device, key approval | Need the server. A phone that is already signed in stays signed in. |
| Live location of others, driving alerts of others, server push | Not available (no server to produce them). |

## 3. Audit: what the code did before this change

Found by reading the code and confirmed with failing tests (fake HTTP client that refuses, times out or answers 5xx).

| # | Defect | Effect | Fix |
| --- | --- | --- | --- |
| 1 | `LocationOutbox.drain` counted every failed send as a strike; 8 failures dropped the points. | A 2-hour outage with the map screen reconnecting every few minutes silently threw away the backlog. | A failure only strikes when the server **refused** the batch for good (4xx); offline, timeouts, 5xx and rate limits never strike. |
| 2 | `SealedQueue._bump` dropped a whole batch after 20 failed uploads, **including 5xx**; `_prune` dropped check-ins and chat after 48 h and displaced them when the queue was full. | A deploy or an outage of a few minutes during frequent flushes lost sealed chat/check-ins in Private circles. | Server trouble never counts; chat, check-ins, places and events are never dropped (only live fixes/history/results are bounded). |
| 3 | SOS: a failed send returned to the idle button with an error text. | The SOS was lost; the person had to remember to press again. | Queue + "not sent yet" state + SMS fallback + retry (section 4). |
| 4 | Check-in and Help alert: error text only. | Lost. | Queue, idempotent replay. |
| 5 | Plain-circle chat: the draft stayed in the box, history was an error card. | No reading, no writing. | Last page cached; send queued with a client id (the server already deduplicated on it). |
| 6 | Map: `fetchMembers` failing showed a full-screen error card and never started the socket. | Empty screen at start without network. | Roster cache (positions encrypted at rest), stale-while-revalidate, chip. |
| 7 | Chat/circles/trips asked `GET /api/profile` only to learn "who am I". | Whole screen failed offline. | Profile cached. |
| 8 | Start-up awaited the session refresh and the config for the full 15 s request timeout. | A blank splash on Wi-Fi without internet. | Capped at 4 s, then opens on the snapshot (the refresh keeps running and still stores a new token pair). |
| 9 | Any transport exception that was not `ClientException` (TLS handshake, reset) escaped as a raw exception; a 200 with a cut-off body threw `FormatException`. | Uncaught errors in screens; cache fallback not used. | All map to an offline `ApiException(0)`. |
| 10 | Nothing told the user the server was unreachable, there was no probe separate from requests, no count of waiting updates. | "Is it me or the server?" | `ServerReachability` + chip + Diagnostics count. |
| 11 | `LocationOutbox.drain` sent one batch (100) per trigger. | A 720-fix backlog needed 8 separate triggers. | `drainAll` (max 12 batches, 400 ms apart). |

Checked and found already good (kept, tests added where useful): token refresh treats network errors and 5xx as "keep the session"
(`refresh_keeps_session_test.dart`), only 400/401/403 from the refresh endpoint end it; the live socket reconnects with exponential
backoff (1 s to 30 s), an inbound-silence watchdog and OS connectivity events; the Private runtime already persisted last positions
(v0.24) and a sealed upload queue with `(circle, device, seq)` idempotency; the chat engine for Private circles is already local-first.

## 4. How it works

### 4.1 Reachability (`services/offline/server_reachability.dart`)

One object knows "can I reach the server". Every request reports in for free (`noteResponse(status)` / `noteFailure()` from
`ApiClient._rawSend`). A failure does **not** flip the chip: it schedules one confirming probe (`GET /healthz`, no auth, 5 s timeout,
2 s later). Only a failed probe says *unreachable*. While unreachable, probes follow exponential backoff with jitter (3 s, doubling,
capped at 5 min, 50 to 100 % of the delay), so there is no tight loop and a family's phones do not return on the same second. Wi-Fi/cellular
events (debounced 800 ms) and the **Try again** button probe at once. A 502/503/504 counts as "down" (a proxy in front of a dead server),
any other status, including 4xx and 500, proves the server is there. When a probe succeeds the recovery hooks flush every queue.

### 4.2 Cache (`services/offline/offline_cache.dart`)

JSON documents in the **Keystore-wrapped vault** (the one that holds the circle keys), under `offline/v1/`. Each document is at most 256 KB,
open-ended groups (trips by date range) keep the newest 30. A locked phone or invalidated key means "no cache right now", never a crash;
nothing falls back to a plain file. Cleared on sign-out. Documents cached: server config, profile, family, circles, roster per scope (kept
current from live frames, written at most every 30 s), places, emergency contacts (for the SMS fallback), recent chat per circle, check-in
inbox, trips, trip details and summaries. The helper `OfflineCache.fetch` returns the live answer and remembers it, or the last copy when the
failure is an *offline* failure (timeout, refused, 408/429/5xx); a 403/404 or a dead session is never hidden by the cache.

### 4.3 Store-and-forward (`services/offline/offline_queue.dart`, existing `LocationOutbox`, existing `SealedQueue`)

| Queue | Holds | Storage | Bounds | Never dropped |
| --- | --- | --- | --- | --- |
| `OfflineQueue` | SOS, Help alert, check-in, plain-circle chat, soft items (settings: newest per key) | vault (falls back to app preferences only if the vault refuses, so an SOS is never lost to a locked phone) | 1000 protected items (a new one is **refused**, not swapped for an older one); soft items 300 / 7 days, oldest first | SOS, check-ins, chat |
| `LocationOutbox` | normal-circle location fixes | app preferences (plain, as before; 12 h / 720) | 720 / 12 h, oldest first | not applicable, fixes are the expendable kind |
| `SealedQueue` | Private-circle sealed items (fixes, check-in positions, chat, events, places) | existing Private store (already ciphertext) | 2000 items; fixes and results go first, 48 h for fixes/history/results | chat, check-ins, events, places |

Replay is in order (SOS first), single flight, stops at the first transport failure and keeps everything. Idempotency: every queued request
carries a client id; the server stores a replay once (chat already did; this change adds it for SOS, Help and check-ins: migration `000340`, and a
replay answers 200 with the stored object and does not count against the cooldown). Items the server refuses for good (4xx) move aside into a
bounded "rejected" list that Diagnostics counts. A 429 on an SOS means the family was just notified, so it counts as delivered. An SOS or check-in
sent late carries "(sent late, pressed at 14:02)" in its note so nobody mistakes it for live.

Private circles keep **sealing locally while offline**: sealing needs only the circle key in the vault, so check-in/SOS positions and chat are
sealed when the person acts and wait as ciphertext. (The Keystore-locked-phone behaviour belongs to another change and is untouched.)

### 4.4 The chip and Diagnostics

`SyncStatusChip` (top of the map): *Server unreachable. Showing last known. Will sync when it is back.* with **Try again** and "N updates waiting";
*Syncing…*; *Up to date* for 3 seconds after a recovery, then nothing. Diagnostics shows "Updates waiting" (positions, messages, check-ins, sealed items together)
with **Send now**.

## 5. Seeing each other without the server: options

What cannot be done by any cache: show **new** movement of someone else while the server is down. For that, a path from their phone to yours
is needed. Four options:

### (a) Cache only: BUILT, always on

Cost: small. Risk: low. Users see the last known position with its age, can queue messages and alerts. They do not see live movement.
This is the baseline and it is enough for "the server is rebooting" and "the home server has no internet for an evening".

### (b) Fallback relay (a second server URL per circle): NOT BUILT, evaluated

Idea: Private-circle items are already end-to-end encrypted and opaque, so a second dumb relay could carry them; the app keeps an ordered list
of base URLs per circle and fails over.

What would have to be true:

* **Protocol.** The items themselves port well: `(circle, device, seq)` is a globally unique id, so duplicates across relays dedupe on seq;
  signatures are in the item, so a relay does not have to be trusted for authenticity. The pull cursor is a relay-local id, so the client would need one
  cursor per relay. The key epoch is the hard part: epochs are set by membership changes that go through the main server. During an outage no
  new member joins and no key rotates; items sealed under an older epoch keep working, items under a newer one stall until the key reaches a phone.
* **Trust.** A relay sees what the main server sees in a Private circle: ciphertext, sizes, purposes, timing, who is a member. Nothing more.
  A **second Orbitly server** would also need the circle, the member list and the registered device keys, plus an account or token per phone,
  i.e. replicating membership and authentication, otherwise it can neither authorize uploads nor rate limit abuse. That is a distributed-systems
  project (membership replication, token acceptance, conflict resolution), not a settings entry.
* **Normal circles.** Positions there are plaintext to the server by design. Sending them to a second server just doubles the exposure.
  Not recommended; normal circles should simply wait for their server.
* **Cost.** Client: relay list per circle, per-relay cursors, health per relay, retry policy, UI (Backup server setting). Server: a relay mode with
  its own accounts or signed-upload auth. Weeks, plus a new attack surface (unauthenticated upload).

Decision: **do not build now.** It is neither small nor safe enough. If the owner wants this, build the "dumb relay" of (d) first, which has no accounts.

### (c) Nearby phone to phone (Bluetooth / Wi-Fi Direct, Nearby Connections): NOT BUILT, recommended against

* Works only when the phones are physically close, i.e. when people can see each other anyway. It does not help with "my mother is at work and the server is down".
* Android Nearby Connections needs Google Play Services (absent on GrapheneOS/LineageOS-without-gapps, which this audience likes); iOS uses a different
  framework (MultipeerConnectivity) with no wire compatibility. Two implementations, background restrictions on both, new permissions
  (`BLUETOOTH_SCAN/ADVERTISE/CONNECT`, `NEARBY_WIFI_DEVICES`), battery cost for continuous advertising.
* Would be a plausible later addition for "meet at the festival without mobile data". Not trivial, so not now.

### (d) Push relay through UnifiedPush / ntfy topics: NOT BUILT, the most promising future path

* The sealed fix item is at most 1 KB (`maxBucket`), chat 8 KB; an ntfy message can carry 4 KB. A topic name derived from the circle key
  (`HKDF(circle key, "relay-topic")`, 128 bit) is unguessable, so the relay needs **no accounts**: whoever knows the topic can publish and
  read, and everything inside is ciphertext with per-device signatures. That is the "minimal relay" of (b) without the replication problem.
* The app already ships UnifiedPush and a direct push service, so the receiving side exists in part.
* Open points: ntfy retention is short (hours, configurable), so this is delivery of *recent* items, not storage; ordering and dedupe
  use the existing seq; the relay (public ntfy.sh or the family's own) learns timing and volume per topic; a leaked topic lets anyone flood it
  (signatures stop forgery, not spam); only Private circles qualify.
* Recommendation: prototype behind an "experimental, Private circles only" switch after the baseline here has been used on real phones. It is a week
  of work plus a threat-model note, not an afternoon.

### What we recommend

1. Ship (a) now (this change). 2. Learn from real use how often servers are unreachable. 3. If live positions during outages matter, build (d)
for Private circles first. Do (b) only if (d) proves insufficient. Skip (c).

## 6. Server side

* `GET /healthz` already existed; the app now uses it as the reachability probe (5 s timeout, no auth, separate from login).
* Migration `000340` adds `client_id` to `alerts` and `checkins` with unique partial indexes `(user_id, client_id)`; `POST /alerts/sos`, `/alerts/help`,
  `/alerts/check-in` and `POST /checkins` accept an optional `client_id` (max 64 characters). A replay returns the stored object with **200** (a first
  send is 201), does no second fan-out, push or SMS, and does not hit the cooldown. Without `client_id` nothing changes. Old servers ignore the field,
  so a queued SOS replayed to an old server could duplicate if the first answer was lost; the app still sends it (a duplicate SOS is the lesser harm).
* The batch location endpoint already deduplicated on `(device_id, ts)`.
* The live socket reconnect already uses backoff (client side); unchanged.

## 7. Known limits

* Creating or editing places of a normal circle offline is not queued (the server assigns the place id, so a replay cannot be idempotent without a larger API change).
  Private-circle places, geofence events and lane preferences already queue as sealed items or retry (`_retryOptOuts`).
* Photo messages need the server. Photos are never queued (size).
* A forced sign-out (the refresh token was explicitly rejected) clears the cache and the queue: they belong to the account, and replaying one account's
  messages under another login would be worse than losing them. A network failure never does that.
* If the vault is locked (phone not yet unlocked after boot) the cache is simply unavailable until the first unlock; the queue falls back to preferences so
  an SOS is kept.
* "Syncing" shows while anything waits and the server answers; a permanently refused item moves aside instead of blocking the chip.
* After a long outage the order of arrival across **different** kinds (chat vs fixes) is not interleaved by time; within a kind it is.

## 8. Tests

`test/services/offline/*` (backoff, reachability and chip, queue, cache, API failure modes), additions to `location_outbox_test.dart` and
`private_channel_test.dart`, the SOS screen and chat in `test/screens/offline_*`, Go `offline_replay_db_test.go`, and the real-server scenario in
`scripts/e2e-lanes.sh` (stop the server container while the phones keep going, restart, everything arrives once and in order).

## 9. Not verified

Real phones (Android/iOS), the real Keystore with a locked phone, real mobile networks (captive portals, carrier NAT, flapping), battery cost of the
probe loop over a full day, the SMS composer on real devices, and iOS entirely. Everything above is verified only with fake clocks, a fake
HTTP transport and the Go/Postgres test server.
