# ADR: Per-member privacy and where data is processed (server-assisted vs phone-only)

Status: **PROPOSED** (design only; no code in this change). Extends `docs/design/E2EE.md` (phases 1 to 3 and "Trusted-server mode").
Audience: the maintainer, and the agents that will implement the phases in section 13.

Everything below was checked against `E2EE.md`, `backend/internal/handlers/e2ee_server_member.go`, `backend/internal/handlers/e2ee_channel.go`,
migrations up to `000186`, and `app/lib/services/e2ee/*`. Where something was not verified it is marked **(unverified)**.

## 1. Context and owner requirements

1. On the phone **every feature stays**: driving reports, trips, history, places, summaries. Features that need a server in a normal circle must still work in some form on the phone.
2. The server stays a **real server** that stores and processes data (admin map, trips, weekly summary, Dawarich sync, push).
3. A **member** can opt out of sending *their* data to the server (circle > Encryption keys, or personal settings) while the circle's end-to-end encryption between phones continues.
4. The opt-out must warn **honestly**: processing then happens on the member's phone (battery, CPU, data) and some features are limited to what a phone can compute.
5. If a circle wants **no server processing at all**, evaluate (a) each phone computes its own stats and shares results as E2EE items, (b) members' phones split or rotate the work, (c) one elected "main processor" phone, and recommend one.
6. **Only the circle admin edits circle-wide settings.** A clear roles model: who changes the circle's server-processing default, who changes a member's personal opt-out.

## 2. The problem in today's design

Trusted-server mode (E2EE.md, `e2ee_server_member()` in migration `000165`) makes the server a device member that holds the **circle key**. It is
all-or-nothing: the server may read a circle only while **every** live member has a signed consent row. Consequences:

* There is exactly one key line per circle epoch (the circle key). Whoever holds it reads **every** member's items. Holding it for "the consenting
  members" is impossible: one member who does not consent closes the circle for everyone (`Residual risks`, "Consent is all-or-nothing per circle").
* Therefore a per-member opt-out cannot be done by simply skipping the consent: the opted-out member's items would still be sealed under the key the server holds.
* The data has to live under **a key the server never holds**, and the choice has to be made **by the author's phone**, not by a server flag, an admin or a session token.

## 3. Decision (summary)

1. **Two key lines per Private circle**, both held by all members' phones:
   * **Phone key `CK`** (the existing circle key and its epochs). **Never wrapped to a `server`-kind device.** Items sealed under it are *phone-only*.
   * **Server key `SK`** (new, own generation counter). Wrapped to all members' phones **and**, when the circle has server assistance enabled, to the pinned server device. Items sealed under it are *server-assisted*.
2. **The sender's phone decides, item by item, which line it seals under**, from its own signed preference. The sender's preference governs everything the sender *authors* (fixes, events, history, check-ins, and places and results they create). The server cannot change it, an admin cannot change it, and an old app that knows nothing of `SK` seals under `CK` (**fail-safe default = private**).
3. **Consent is per member, not per circle.** The existing signed server consent now means "my phone seals my items under `SK`". No consent row means phone-only. A member without consent no longer closes the circle.
4. **Circle admin** controls circle-wide policy: whether server assistance exists for the circle at all, and the default shown to new members. **Each member** controls their own lane, and only their phone can sign it. An admin cannot opt a member in. (Children: open question Q3.)
5. **Phone-only data is processed on the author's phone and published as E2EE result items** (option (a)). Rotation of load between phones (b) and an elected processor (c) are rejected as primary designs (section 9). An optional, never-required "always-on hub" device is allowed later as pure acceleration.
6. **Graceful degradation is explicit data**: every member row, every result and every screen carries `processing: server | phone` and the UI shows which, so a missing server trip is shown as "computed on Alex's phone" or "not available (Alex keeps data on their phone and this phone cannot compute it yet)", never as an empty screen.

## 4. Threat model and what each mode protects

Adversaries (same list as E2EE.md, plus the new ones this ADR creates):

| Adversary | Standard circle | Private, phones only | Private, server-assisted: member who opted IN | Same circle: member who opted OUT |
|---|---|---|---|---|
| Server DB breach / stolen backup | plaintext positions | ciphertext + public keys + metadata | **plaintext** copies (`locations`, `member_positions`) plus ciphertext whose key may sit in the sidecar volume | ciphertext + metadata only |
| Curious / compelled operator | reads everything | metadata only | reads everything of this member | metadata only |
| Compromised server host (root) | everything | metadata only; can add a malicious *public* key (limit already in E2EE.md) | everything of opted-in members, **and** the sidecar volume (SK) | metadata only, **provided phones never wrap `CK` to a server-kind or unapproved key** |
| Network observer | TLS | TLS + ciphertext | same | same |
| Hostile or compromised **member** | sees all | sees all (holds `CK` and `SK`) | sees all | sees all. **Opt-out does not hide data from other members.** If member A runs a bridge or a viewer, A can export what A's keys decrypt, including B's phone-only items |
| Platform admin (operator) | admin map | none | admin map for opted-in members only | nothing |
| Circle admin | can see members | same as member | same | same; cannot read more than any member, cannot flip B's lane |

What the opt-out **does not** protect, stated in the product text:

* **Metadata the server always sees**: that B uploads, upload times (minute), item sizes (bucketed), purposes (`fix`, `event`, `checkin`, `history`), the item's key line (`phone` or `server`), push tokens, IP addresses. Adaptive upload cadence reveals "moving vs still". Not hidden in any mode.
* **Other circles.** Positions are per user, not per circle (E2EE.md, "multi-circle rule"). If B also sits in a Standard circle, B's phone still uploads plaintext for that circle. The opt-out is **per Private circle**; the screen must say "you are also in a normal circle, which still sends your position to the server".
* **Data already copied.** Server plaintext copies made before the opt-out, trips already built, notifications already sent, backups, data exported to Dawarich. Only the tagged `locations` rows and the sealed ciphertext can be deleted (section 8).
* **Members.** A member already holds the keys (E2EE.md out of scope: hostile member).
* **A malicious server with write access to the DB can still withhold wraps, items or consents** (availability), and can show a false "processed by server" badge. It cannot make B's phone seal under `SK`; the badge is derived by phones from verified item headers and the signed log, not from a server flag.

What server-assisted really means: **for the opted-in members the server is a trusted party that can read everything and keeps plaintext at rest.** That is the point of that mode (E2EE.md says the same). E2EE between phones continues in both modes, but the *confidentiality against the server* exists only for phone-only items.

## 5. Cryptographic design (new frozen formats; vectors required, Go and Dart)

### 5.1 Key lines

* `CK` / `circles.e2ee_epoch`: unchanged semantics. Rotates on member removal or key revocation (existing triggers).
* `SK` / `circles.e2ee_server_gen` (new, starts at 1 when server assistance is first enabled): 32 random bytes made by an admin phone, wrapped with the existing sealed-box wrap (E2EE.md, "Sealed-box wrap") to every approved member device and the recovery keys. The wrap AAD gains the line: `"OFE2EE3-WRAP-AAD\0" || line(1) || circle_id || gen || recipient_device_id || wrapper_device_id`, so a `CK` wrap can never be replayed as an `SK` wrap.
* Domain separation: the HKDF subkey for items is derived per (key, circle, **line**, gen, purpose); the info string starts `OFE2EE3-`.
* `SK` rotates on the same triggers as `CK` (member removed, key revoked, consent withdrawn by the last server member) **and** whenever server assistance is turned off then on. It is rotated by an admin phone (publisher rule unchanged).
* A key commitment for `SK` is published like the existing epoch commitment, so every member provably holds the same `SK` (a wrapper cannot hand different members different keys).

### 5.2 Item format v2

```
payload  = 0x02 || line(1: 0x00 phone, 0x01 server) || gen(4 BE) || nonce(24) || ct || tag(16)
sig      = Ed25519(sender DEVICE key, "OFE2EE3-ITEM\0" || circle_id || line || gen(4) || device_id ||
                   len(purpose)(1) || purpose || seq(8) || ts_ms(8) || body)
AAD      = "OFE2EE3-ITEM-AAD\0" || circle_id || line || gen || device_id || purpose
```

* v1 items (header `0x01`) keep their meaning: line = phone, gen = epoch, **except** in a migrated legacy trusted-server circle (section 11).
* `line` and `gen` are in the signature and the AAD: the server cannot relabel an item, and a wrong label simply fails to decrypt.
* Padding buckets, `seq`, replay window, epoch-rollback rule: unchanged, applied **per (line)**: the rollback rule is tracked per line (a newer `SK` gen does not outdate `CK` and vice versa).
* The server validates the header exactly as for v1 (length, bucket, declared == header), additionally `line` in `{phone, server}` and, for `server`, that the circle has server assistance on and `gen <= e2ee_server_gen`. It stores `key_line` in the row. This is **routing metadata**, not trust: the sidecar only opens `key_line='server'` rows and can only open them if they really are sealed under `SK`.

### 5.3 Signed policy entries (transparency log)

Two new immutable log actions, signed by an active key of the actor like every other action:

| Action | Signed by | Meaning |
|---|---|---|
| `processing_policy` | circle admin | `{circle, server_assist: on|off, default_for_new: server|phone, sk_gen, commitment}` |
| `processing_pref` | the member | `{circle, user, lane: server|phone, effective_seq}` (this is also the per-member consent: message below) |

Consent message (supersedes `OFE2EE1-SERVERCONSENT`; the old vector stays valid for legacy rows):
`"OFE2EE3-PROCESSING\0" || circle || user || lane || sk_gen || server_device_id || server_fingerprint || nonce`.
`lane = server` requires the pinned server fingerprint (so consent names the exact server key); `lane = phone` needs no server key. Withdrawal is a new entry (`lane=phone`), not a delete, so the log shows when a member switched.

Phones verify, per sender, that items with `line=server` come from a member whose latest valid pref is `server` (or from before a pref change by signed time); an item sealed under `SK` by someone who is phone-only is *accepted but flagged* (a hostile member could do it; it is not a server-attack). The UI badge "server-processed" comes from this check.

### 5.4 Who may wrap what (hard rules, enforced by triggers and by phones)

1. `CK` is **never** wrapped to `kind='server'`. Server-side trigger rejects it; phones never create it (`_recipients(line=phone)` excludes `server`). Today's code wraps the circle key to the server device in `processPending/_recipients` when `allowedServerKey` holds; this must change to the `SK` line only (phase 3 below).
2. `SK` is wrapped to the server device only if all hold: admin `processing_policy` on, the pinned key is active and approved, its wrap is made by a phone, and **at least one member has `lane=server`** (so an `SK` held by the server with no consenting author is never created for nothing).
3. `service` devices (the standalone Dawarich bridge) get `SK` by default and `CK` only by the explicit decision of their owner's phone; `web` viewers get both (they are the owner's own eyes). Each gets an "includes phone-only data of everybody" warning (section 7).

## 6. Data model sketch (migration `000187_processing_lanes`, idempotent, with down file)

```sql
ALTER TABLE circles
  ADD COLUMN IF NOT EXISTS server_assist        BOOLEAN NOT NULL DEFAULT FALSE,   -- admin policy, mirrors the signed log entry
  ADD COLUMN IF NOT EXISTS server_assist_default TEXT   NOT NULL DEFAULT 'phone'  CHECK (server_assist_default IN ('phone','server')),
  ADD COLUMN IF NOT EXISTS e2ee_server_gen      INTEGER NOT NULL DEFAULT 0;

-- line on wraps and items; existing rows are the phone line
ALTER TABLE circle_key_wraps ADD COLUMN IF NOT EXISTS key_line TEXT NOT NULL DEFAULT 'phone' CHECK (key_line IN ('phone','server'));
-- PK/unique of circle_key_wraps extended with key_line (recreate index; keep old name for rollback)
ALTER TABLE e2ee_items       ADD COLUMN IF NOT EXISTS key_line TEXT NOT NULL DEFAULT 'phone' CHECK (key_line IN ('phone','server'));
CREATE INDEX IF NOT EXISTS e2ee_items_circle_line ON e2ee_items (circle_id, key_line, id);

-- per member lane; replaces "no row = blocks the whole circle" with "no row = phone"
CREATE TABLE IF NOT EXISTS e2ee_processing_pref (
  circle_id UUID NOT NULL, user_id UUID NOT NULL,
  lane TEXT NOT NULL CHECK (lane IN ('phone','server')),
  sk_gen INTEGER NOT NULL, server_device_id UUID, approver_device_id UUID NOT NULL,
  signature BYTEA NOT NULL, signed_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (circle_id, user_id));
-- e2ee_server_consents is kept (legacy rows are read as lane='server'); a view or data migration unions them.

-- client capabilities so an admin cannot enable SK while a member's app cannot read it
ALTER TABLE device_keys ADD COLUMN IF NOT EXISTS caps TEXT[] NOT NULL DEFAULT '{}';   -- e.g. {'lanes2'}

-- triggers
--  * refuse a CK wrap whose recipient kind = 'server'  (key_line='phone')
--  * refuse an SK wrap to 'server' unless e2ee_server_assist(circle) AND >=1 pref lane='server'
--  * member removal / key revoke: delete wraps (existing) and set e2ee_rekey_required for BOTH lines
--  * server assist turned off: delete SK wraps of the server key and all e2ee_processing_pref rows with lane='server'
-- functions
--  e2ee_server_assist(circle)            = private AND server_assist AND pinned key approved AND holds CURRENT SK gen wrap
--  e2ee_member_server_ok(circle, user)   = e2ee_server_assist AND pref(user).lane='server' AND signature chain valid (re-verified in Go)
--  e2ee_plaintext_blocked(circle)        unchanged shape, but per-user for ingest: blocked unless e2ee_member_server_ok
```

`e2ee_server_member(circle)` stays as a compatibility alias for `e2ee_server_assist` so existing handlers keep compiling; handlers that guarded "may the server hold plaintext for this circle" become **per user** (`e2ee_member_server_ok`): ingest, server geofence, `circles.Authz` visibility queries, SOS position rule, purge.

Server-side marking of processed vs phone-only data:

* `e2ee_items.key_line` (routing) and, for plaintext tables, the existing `source='e2ee_server'` and `locations.e2ee_circle_id` tags.
* `GET /circles/{id}/members` and `GET /circles/{id}/e2ee/processing` expose per member `{lane, since, sk_gen_ok}` (from the verified pref). Screens read it to decide "ask the server" or "read the phone's own result items".
* Server-computed endpoints (`/trips`, `/driving/*`, weekly) add `processing: "server"` to each member's block and **omit** phone-only members with `phone_only_members: [user_ids]` so a client never mistakes "no rows" for "no trips".

## 7. API additions

| Route | Who | Purpose |
|---|---|---|
| `PUT /circles/{id}/e2ee/processing-policy` | circle **admin**, signed `processing_policy` | turn server assistance on/off, set default for new members, publish `SK` gen (with wraps in the same call, like `epoch`) |
| `GET /circles/{id}/e2ee/processing` | member | policy, `sk_gen`, per-member lane and since, server fingerprint, whether every member's app supports lanes (`caps`) |
| `PUT /circles/{id}/e2ee/processing-pref` | the member (own, signed by own phone) | opt in/out; replaces `PUT .../server-consent` (old route kept as alias for lane=server) |
| `DELETE /circles/{id}/e2ee/server-copies?scope=mine|circle` | member / admin | existing: tagged `locations` rows; **extended** to also erase `e2ee_items` with `key_line='server'` of the caller (or circle) |
| `POST /circles/{id}/e2ee/wraps` | existing | gains `key_line`; same publisher rules; `SK` publisher = admin |
| `POST /circles/{id}/e2ee/batch`, `GET .../items` | existing | accept/return v2 items, `key_line`; `GET` gains `key_line=` filter; the sidecar uses `key_line=server` |
| `POST /circles/{id}/e2ee/results` is **not** needed | | results are normal items with new purposes `trip`, `drive`, `week` (see 8.4), sealed under the author's lane |
| `POST /internal/e2ee/ingest` | sidecar token | unchanged contract, now checks `e2ee_member_server_ok` per user; unreadable members never appear |
| `GET /api/admin/e2ee/keys` | platform admin | shows lanes per circle as counts (no user-visible detail beyond what it shows today) |

Role enforcement is server-side (`circles.RequireAdmin`): `policy` = admin only; `pref` = self only, and **no endpoint lets any role write another user's pref**.

## 8. Behaviour of the transitions

### 8.1 Admin turns server assistance on (Private circle)

1. Preconditions the admin phone checks: instance has a pinned, approved server device; all members' devices advertise `lanes2` (otherwise the screen lists who must update, and nothing is enabled).
2. Admin phone generates `SK` gen 1, wraps it to every approved member device and recovery key, publishes a signed `processing_policy`. **Nobody is opted in yet**; the server gets no `SK` wrap yet (rule 5.4.2).
3. Every member gets a prompt (wording in 10.3) with the admin's default pre-selected. Until they answer: phone-only. A member answers by signing a pref (lane=server or phone).
4. When the first member signs `lane=server`, an admin phone (or that member's phone if it is the `SK` publisher) wraps `SK` to the server key. The server sidecar starts opening `key_line=server` items.

### 8.2 Member opts OUT (server to phone)

1. Phone signs `processing_pref lane=phone`, switches `ChannelSealer` to the `CK` line for all **new** items (events, fixes, history, check-ins, places authored by this member). In-flight items already sealed under `SK` and queued are re-sealed under `CK` before upload (the `SealedQueue` stores plaintext body hash + metadata for this; **otherwise**: drop and re-create; never upload an `SK` item after the pref change).
2. The phone also stops all plaintext uploads for the circle (it already does in a Private circle) and the server stops ingesting the user (`e2ee_member_server_ok` false at once).
3. The app **offers, defaults on**, "Delete my copies on the server": calls `DELETE .../server-copies?scope=mine` (tagged `locations`, last-known position recomputation as today, plus ciphertext with `key_line='server'`).
4. **No key rotation is required for the opt-out itself**: the server never held `CK`, and `SK` still protects other members' consented data from outsiders. Rotation is required only if the server's `SK` wrap should end (last server member left: section 8.5).
5. What cannot be undone: the server keeps whatever it already derived; the SK-sealed ciphertext that was never deleted stays decryptable by the server (it keeps old `SK` gens). Hence the delete offer, and the honest text.
6. Features: the member's trips, driving reports and weekly figures are now produced by their phone (8.4). Server-side geofence stops for this member; their phone's place evaluation (already the source of truth for alerts in Private circles) continues, the alert is a sealed `event` under `CK`, and the push is a content-free wake-up as in phase 2.

### 8.3 Member opts IN (phone to server)

1. Needs the pinned server fingerprint (shown, compared with the operator's value as today), `SK` gen current, and the explicit warning (10.2). Phone signs `processing_pref lane=server` and starts sealing new items under `SK`.
2. Past phone-only items stay phone-only. **Backfill is a separate, user-initiated action** ("Also let the server process my last 7 days"): re-seals the phone's local history store under `SK` and uploads it. Not automatic, because it is the one step that would reveal old location to the server.
3. No rotation.

### 8.4 Phone-only processing and graceful degradation

A phone-only member's phone computes, **incrementally** on the fixes it already has, the same derived data the server would, and publishes it as result items (sealed under `CK`, tiny, retention like `history`):

| Purpose | Body | Computed from | Notes |
|---|---|---|---|
| `trip` | `{id, s, e, dist, dur, from?, to?, mode?, polyline?}` | local fixes, segmented on-device (stop detection, distance, duration) | the repo already has on-device motion/driving code (`app/lib/services/driving/*`, `motion_detector.dart`); trip segmentation on device is **new** (E2EE.md lists phone-side trips as future) |
| `drive` | `{trip, events:[...], score, phone_use_s}` | `driving_runtime`, `handling_analyzer`, `phone_use_tracker` (already on device for events) | the on-device event stream exists; aggregation/scoring to the server's definition must be ported and pinned by shared vectors |
| `week` | `{wk, trips, km, drive_min, places, top_places, score}` | the member's own `trip`/`drive` | each phone makes its own; the family summary screen **composes** them |

* Rules: result items are signed by the author's device (existing item signature); newest `wk`/`id` wins; deterministic algorithms plus shared test vectors so a server-produced and a phone-produced trip for the same fixes agree to a tolerance.
* The "family weekly summary" and driving list screens render per member: `server` source (REST) for server-assisted members, result items for phone-only members, and a labelled placeholder when a phone-only member has not yet published (their phone was off). **Nothing is silently dropped.**
* Not computable on a phone (listed, shown as "needs the server"): reverse geocoding of every stop (the phone can geocode on demand through the existing geocoding service, which sends a coordinate to the geocoder: **a privacy leak to name it**, off by default for phone-only members, place names from the circle's own places only), map-matching, cross-member comparisons that need other members' raw fixes older than their local window, history older than the sealed chunks the phone kept, live-share links, "request location" while the target phone is asleep, platform-admin map, built-in Dawarich sync for this member.
* Cost honesty: sealing and signing are already paid in phase 2. New cost is trip/driving aggregation (incremental, per fix) and one result upload per trip/week. Battery and CPU numbers are **unmeasured**; Phase 0 below measures them on a mid-range Android and an iPhone before any claim goes in the UI. The user text says "may use more battery" and shows measured figures only once they exist.

### 8.5 Admin turns server assistance off

1. Signed `processing_policy off`; trigger deletes the server key's `SK` wraps and all `lane=server` prefs; ingest answers 403 for the circle.
2. All members seal under `CK` from the next item. Admin phone rotates `SK` (new gen, no server wrap) only if re-enabling later is wanted; rotation is not needed for confidentiality (the server's old `SK` can only decrypt what was already sealed for it).
3. Admin screen offers **Delete all server copies** (`scope=circle`). The text says what survives (backups, Dawarich, derived data).

### 8.6 Member leaves or is removed, key revoked

Existing triggers set `e2ee_rekey_required`; it now covers both lines. `CK` rotates as today. `SK` rotates too (the removed member held it) and is re-wrapped to the server only while at least one remaining member is `lane=server`. A removed member's `processing_pref` row is deleted; their server copies are **not** deleted automatically (history of the circle, existing rule), the admin can purge.

### 8.7 New member joins

Gets `CK` and `SK` wraps from the (now longer) publisher chain exactly as `CK` today (availability caveat in E2EE.md 6: waits for an admin phone). Joins as phone-only until they sign a pref. The invite screen tells them how the circle is set up before they accept.

### 8.8 On-device geofencing (unchanged logic, lane-aware output)

Places remain sealed items evaluated by the sender's phone. New rule: a place is sealed under the **creator's** lane. Server-side geofencing can therefore only evaluate server places and `SK`-sealed places that the sidecar imports (the sidecar still does **not** import places in this design; E2EE.md "one source of truth" stays: phones alert). A phone-only member's `Home` place is never readable by the server; an opted-in member's place is readable and can be used for server place names. An `event` is sealed under the **sender's** lane, so "Alex arrived at Home" is readable by the server only if Alex opted in.

### 8.9 Admin web viewer, Dawarich bridge, server device

* **Browser viewer** (`web` key) is the owner's own device and decrypts with whichever lines the owner's phone wrapped to it (default both). It does not depend on the lane of the owner.
* **Platform admin map** is fed only from the plaintext tables, i.e. only `lane=server` members. A phone-only member shows as "keeps data on their phone" instead of "no signal".
* **Built-in Dawarich sync** reads plaintext tables: only opted-in members. **The `e2ee-bridge` as `service` device** (owner-run, off host) gets `SK` by default; if its owner's phone also gives it `CK`, it exports phone-only members too, which breaks the expectation of those members. Therefore wrapping `CK` to a `service` key requires a dedicated warning on the owner's phone and a log entry; the other members see "A's Dawarich bridge can read phone-only data" in the circle screen. Recommended default: never.
* **The server device** (`server` kind) never receives `CK` (rule 5.4.1). The sidecar now also verifies each `lane=server` author via the log before ingest (it already re-verifies consents).

## 9. Options for a circle that wants **no** server processing

Baseline fact that holds for all three: the server still relays ciphertext and push wake-ups. A circle with no server at all (peer to peer) is out of scope; no rendezvous, no push, and iOS cannot receive background data without APNs.

| | (a) Each phone computes its own, shares results | (b) Phones split/rotate the processing | (c) One elected "main processor" phone |
|---|---|---|---|
| Idea | Author computes derived data from their own fixes, publishes result items | Members take turns/shards computing for everyone | One phone holds everyone's data view and publishes all derived data |
| Mobile OS reality | Needs only the author's own background location, which the app already has. Computation is incremental, can be batched when the app is running or charging | Needs **other** members' fixes at the computing phone and an available phone at the right time. iOS gives no scheduled background execution guarantee (`BGTaskScheduler` is opportunistic, minutes to hours), Android Doze/OEM killers delay or kill. Nothing runs "when needed" | Same as (b) but one phone must be reachable continuously. iOS cannot. Android needs a foreground service and a battery-optimisation exemption, and still dies on reboot or OEM kill |
| Battery | Each phone pays for its own path, roughly the cost it already pays for sealing + the incremental aggregation | Everyone pays, plus pulling and decrypting others' data, plus duplicated work to cover failures | One phone is drained; the user will turn it off |
| Availability | Result is late if the author's phone was off, but **loss is bounded to the author's own data** | Late and non-deterministic; "who owns shard X?" needs coordination with no coordinator | Single point of failure; whoever is the processor going offline stops everyone's summaries |
| Correctness / trust | Author-signed; same trust as the author's fixes. Can lie about own trip, which is harmless to others | The computing phone can **forge** a result for another member, and receivers cannot cheaply verify without recomputing from raw data (which they would have to fetch) | Same forgery issue, with maximal authority concentrated in one person; consensus/election protocol needed, split-brain on partition |
| Complexity | Low. New purposes + on-device aggregation + UI | Very high (scheduling, failure detection, duplication, fairness, ordering) | High (election, handover, key custody, mitigations for dead processor) |
| Verdict | **Recommended** | **Rejected as primary.** Keep one cheap piece: any phone *may* compute and publish a result for an input range that is missing (deterministic, content-addressed by author+range, newest signature wins; duplicates are harmless). Opportunistic, never required | **Rejected as elected role.** Offer instead an optional **"home hub"**: a plugged-in Android device or a member-run `service` bridge/`e2ee-bridge` on the owner's hardware that is *just another phone-like member* computing results for those who want faster summaries. It is a convenience, not a dependency. In effect it is the self-hosted server the owner already runs, with all the trust that implies (it must hold `CK`) |

Recommendation: **(a) for the phone-only lane, plus opportunistic fill-in by any phone, plus an optional hub that the circle explicitly approves as a device member.** (b) and (c) fail the owner's own test of correctness and availability on mobile OSes.

Honest consequences for a phone-only circle: summaries lag when a phone was off; only what a phone can compute exists; there is no server admin map, no Dawarich built-in sync, no live-share links, no geocoded trip names by default.

## 10. Roles and permissions

### 10.1 Roles

Roles already exist in `circle_members.role` (`admin | member | child`, migration `000001`). The platform admin (`users.role = admin`, the instance operator) is a separate axis and gets **no** power over circle settings.

| Action | Circle admin | Member | Child | Platform admin (operator) |
|---|---|---|---|---|
| Rename circle, edit name/settings (`PATCH /circles/{id}`) | yes (`RequireGraceAdmin`) | no | no | no |
| Add/remove members, change roles | yes | no | no | no |
| Turn Private circle on/off, publish `CK` epoch, approve replacement keys | yes | no | no | no |
| **Turn server assistance on/off, change default for new members** | **yes (signed policy)** | no | no | no |
| Run the server device, set `E2EE_SERVER_INGEST_TOKEN`, pin the server key | no | no | no | **yes (instance level only)** |
| **Opt myself in/out of server processing** | yes (own) | yes (own) | see Q3 | no |
| Opt **another member** in/out | **no one** | no | no | no |
| Delete my own server copies | yes | yes | yes (via guardian, Q3) | no |
| Delete everyone's server copies in the circle | yes | no | no | no |
| Grant my `CK` to my own `service` bridge | self | self | no | no |
| Pause/stop sharing (existing) | own | own | own | no |
| View who is server/phone | yes | yes | yes | counts only |

### 10.2 Rules

* **Two layers, two owners.** Circle-wide *availability* of server processing = admin. *Participation of my data* = me. Both must be true for my data to reach the server. Admin policy off beats everything; a member's `phone` beats admin policy on.
* **The admin default is a default shown to joiners, never an outcome.** A signed pref from the member's own phone is always required to read their data (existing principle: consent needs a phone signature).
* Every state change is a signed log entry visible to all members ("Alex switched to phone-only"). A member can see, but not veto, an admin turning assistance on; a member can leave the circle or stay phone-only.
* Server-side audit of existing circle endpoints for role checks is a task in phase 6 (I verified `UpdateCircle` uses `RequireGraceAdmin` and `UpdateCircleMemberRole` is admin only; I did **not** audit every circle-scoped handler, e.g. silence-alert settings, sharing, retention). Any circle-wide setting found without an admin check is a bug to fix.

### 10.3 UI flows and warning wording

Entry points: **Circle > Encryption keys > Processing** (policy for admins, preference for everyone) and **Settings > Privacy > Where my data is processed** (list of my circles with the same switch).

**Circle screen badge** (replaces "Server can read"): `Private, phones only` / `Private, server-assisted (2 of 4 members)`. Member rows show a small icon: server or phone.

**Admin: turn on server assistance**
> Turn on server processing for this circle?
> The OpenFamily server will be able to read the location, trips and driving data of members who allow it. It stores that data in readable form on the server. It enables the admin map, history, trips, weekly summaries and Dawarich export for those members.
> Each member decides for themselves. Members who say no keep end-to-end encryption and their phone does the processing. You cannot change another member's choice.
> Default shown to new members: [Server processing] [Phone only]
> [Turn on] [Cancel]
> Blocked: "Sam's app is out of date and cannot use this yet." (list)

**Member: opt out** (switch off "Let the server process my data")
> Keep your data on your phone only?
> Your location will stay encrypted. The server will no longer be able to read it. Your phone will do the work instead:
> - It may use more battery and some mobile data.
> - Trips, driving reports and weekly summaries are calculated on your phone and shared with the circle once your phone has done it. They can arrive late if your phone is off.
> - Some things will be limited: place names, admin map, live-share links, "request location" when your phone is asleep, and the server's Dawarich export will not include you.
> Others in the circle can still see your data. If you are also in a normal circle, that circle still sends your position to the server.
> [ ] Also delete my existing copies from the server (recommended). Backups and anything already exported cannot be deleted.
> [Keep on my phone] [Cancel]

**Member: opt in**
> Let the server process your data?
> The server will be able to read your location, trips and driving data and stores a readable copy. This turns on the admin map, history, trips, driving reports and weekly summaries without using your phone's battery for them. Anyone who runs or backs up this server can read it.
> Server key to compare with the one your admin sees: `ab12 cd34 ...`
> [Allow] [Cancel]    (destructive-styled, same pattern as the existing "Allow the server to read this circle")

**Join screen**: shows the circle's setup in one line each: "Private circle. Server processing: on. You choose for your own data" with the default pre-selected and the safe option equal weight.

**Degraded placeholders**: "Computed on Alex's phone. Updated 2 h ago." and "Alex keeps data on their phone. Their phone has not shared a summary yet."

## 11. Migration of existing circles

| Existing circle | Result | Notes |
|---|---|---|
| Standard (plaintext) | Unchanged. No opt-out exists because the server already reads plaintext | The screen shows "Server reads this circle. Turn on Private circle (admin) to let each member choose". Turning on Private is the existing flow |
| Private, no server device | = "phones only" | No data change. Admin may enable server assistance (8.1) |
| Private with trusted-server mode | Legacy: all members consented, server holds `CK` at epochs <= N. Migration (admin phone, one explicit action "Upgrade privacy controls", requires all members `lanes2`): (1) record `server_legacy_epoch_max = N`: items at v1 epochs <= N are treated as line=server; (2) admin publishes `CK` epoch N+1 that is **not** wrapped to the server (the server loses the ability to read new `CK` items); (3) admin generates `SK` gen 1, wraps to members and server; (4) each existing consent row becomes `lane=server` (valid because it names the same server key; re-verified in Go); (5) members can then opt out individually | Until the upgrade runs, the circle keeps old behaviour and the old apps keep working. Old apps after the upgrade seal under `CK` (v1 format): fail-safe, they stop feeding the server rather than leaking, but they cannot read `SK` items, hence the `caps` gate |
| Dawarich bridge (`service` key) | Keeps `CK` epochs <= N it already holds; for epoch N+1 and `SK` its owner's phone must decide (default `SK` only) | The bridge cannot be silently starved: it reports "missing wrap for line=phone"; owners are told |

Rollback: the down migration keeps `key_line` columns (additive); server assistance can be set off, which restores plain Private behaviour. Items already sealed v2 need the new client; do not ship a client that cannot read v2 before the server accepts v2.

## 12. Risks and open questions

Risks:

1. **Wire format change.** Third item/wrap format; needs cross-language vectors, an audit, and a long compatibility window. Mitigation: additive version byte, v1 retained, server rejects v2 until `caps` allow.
2. **Re-sealing the queue on opt-out.** If implemented wrongly, an `SK` item could be uploaded after the pref change. Needs a test that fails hard (the sealer must read the pref at seal time and at upload time).
3. **`CK` accidentally wrapped to the server** by existing code paths (`_recipients`, `processPending`). A server-side trigger is the backstop; phones are the primary guard.
4. **Metadata and the multi-circle rule** make the opt-out less private than it sounds; the UI must say so.
5. **On-device aggregation fidelity.** Server and phone results may differ. Pinned algorithm vectors and tolerances, otherwise members see two trip counts.
6. **iOS background execution.** Phone-only processing relies on the app running; iOS location background mode keeps it running only while significant-change/continuous updates are active. **(unverified, and E2EE.md says phone background behaviour is itself not yet verified on devices)**.
7. **A member who is phone-only still holds `SK`.** If their phone is compromised, `SK` leaks, which exposes only the data of opted-in members (who accepted the server's readability anyway).
8. **Social pressure:** an admin may pressure members to opt in. The model makes it visible (signed log), not impossible.
9. **Complexity of two lines** in screens that mix server and phone sources. Mitigated by the single `processing` field and one data-access layer (`ProcessingSource`).

Open questions for the owner:

* Q1. Are places created by an opted-in member readable by the server (so server place names work), or should places always default to the phone lane? (Design: creator's lane.)
* Q2. Should the platform admin map show phone-only members as "keeps data on phone" (leaks the existence of the choice, which the server sees anyway) or hide them?
* Q3. Children: parents hold the phone at pairing; allow a guardian-made pref on the child's phone only during pairing, or let the admin set a *policy* that the child's app honours but cannot cryptographically enforce? Recommendation: pairing-time choice only, plus a visible badge; no remote admin override, because that would defeat the signature principle.
* Q4. Should a phone-only member's `week` and `trip` results be encrypted under `CK` only, or may the member share a *summary* with the server (publishing only anonymised aggregates under `SK`)? Recommendation: no, keep results in the member's lane for v1.
* Q5. Do we ship the optional "home hub" in this effort or leave it as documented-only?
* Q6. Should opted-in backfill (8.3) exist at all in v1? It is the only step that reveals past location to the server.
* Q7. `caps` gating blocks enabling server assistance for circles with abandoned old apps. Is "remove the stale member" acceptable?

## 13. Test plan

Crypto and vectors (Go and Dart, shared `testdata/lanes.json`): v2 item seal/open for both lines; `line`/`gen` tamper fails signature and AEAD; `CK` wrap replayed as `SK` fails (AAD); cross-line key confusion; rollback rule per line; commitment for `SK`; consent message binds circle, user, lane, gen, server fingerprint (movement across any field fails); legacy consent vector still verifies.

Server DB tests (pattern of `e2ee_server_member_db_test.go`):
* trigger refuses `CK` wrap to a `server` key under every path (direct SQL, `POST wraps` with several actors);
* `SK` wrap to server refused until policy on + at least one `lane=server`; revoked at policy off;
* ingest: members with `lane=phone` and members without a pref are never written (the existing `PlantedConsentRows` style test: a planted row must not make ingest accept);
* a circle with one opted-out member: opted-in member's fix reaches `locations`; opted-out member's sealed fix is stored as `key_line=phone` and no plaintext row appears anywhere (scan the DB, logs and audit rows for coordinates);
* per-user `circles.Authz` queries do not expose the opted-out member's plaintext through any path, including WebSocket fan-out;
* member removed: both lines flag rekey; server `SK` only wrapped while a server member remains;
* role matrix: non-admin gets 403 on policy; user A cannot write B's pref (404/403); platform admin cannot touch circle policy; child limits per Q3;
* purge: `scope=mine` deletes tagged rows and `key_line=server` ciphertext, leaves `key_line=phone`; last-known position recomputation as today;
* migration: legacy trusted-server circle upgrade preserves reading of old items by the server and denies new `CK` items; idempotent re-run; down migration.

Phone tests (Dart): `ChannelSealer` lane selection from pref; pref flip mid-queue never uploads an `SK` item after an opt-out; old-app simulation (v1 sealer) in an upgraded circle is read correctly and never reaches the server; `_recipients(line=phone)` never contains a `server` key under the existing `allowedServerKey` condition; badges derived from verified headers, not from server flags; on-device `trip`/`drive`/`week` aggregation matches server output on shared fixture tracks within tolerance; UI golden tests for the three dialogs; placeholder rendering for missing results.

End to end (docker compose, profile `e2ee-server`): 3 simulated phones, one opted out; admin map shows two; Dawarich built-in export contains two; the bridge-as-service gets `SK` only; opt-out then delete verifies server DB has no plaintext for that user; re-opt-in.

Physical device tests (required before any "battery" claim): Android (Pixel + one aggressive-OEM device) and an iPhone, 24 h each, phone-only lane versus server lane, with a driving session; measure CPU time, battery %, bytes. **Not done; no claim in UI until done.**

## 14. Phased implementation plan (sized for separate agents)

| Phase | Scope | Size | Depends on |
|---|---|---|---|
| 0 Spike and measurement | On-device trip segmentation + driving aggregation prototype on recorded tracks; measure battery/CPU/data on devices; decide fidelity vs the server algorithms; write vectors for algorithms | M (1 agent, plus human device time) | none |
| 1 Crypto and wire formats | v2 item, wrap AAD with line, `SK` commitment, `processing_pref` and `processing_policy` messages in `backend/internal/e2ee` and `app/lib/services/e2ee/e2ee_crypto.dart`; shared vectors | M | none |
| 2 Server | Migration `000187`, triggers, functions, item/wrap validation with `key_line`, `processing` endpoints, per-user gating in ingest/Authz/geofence/SOS/purge, admin counts, `caps` registration, role checks, DB tests | L (split: schema+triggers / handlers+tests) | 1 |
| 3 Sidecar | `e2ee-bridge` server mode: `SK` only, per-author lane verification, no-`CK` guarantee, missing-wrap reporting | S-M | 1, 2 |
| 4 Phone core | `ChannelSealer` lanes, `SK` custody, wrap logic (`_recipients` by line), pref signing, queue re-seal/drop, receiver checks, per-line rollback, badges | L | 1, 2 |
| 5 Phone processing | `trip`/`drive`/`week` producers and consumers, per-member merged screens, placeholders, geocoding-off default for phone-only | L (split: producers / screens) | 0, 4 |
| 6 UI and roles | Processing screens (admin policy, member pref, settings entry), warning dialogs, join screen, copy review; audit of all circle-scoped handlers for admin checks (silence, sharing, retention) and fixes; docs | M | 2, 4 |
| 7 Migration and release | Legacy trusted-server upgrade action, `caps` gating UI, rollback notes, compose/docs, E2E suite, security review pass against section 4 | M | 2 to 6 |

Phases 1 and 0 can run in parallel; 2 and 4 in parallel after 1 (agreeing on the vector file); 3 after 2; 5 after 4; 6 and 7 last. Update `docs/design/E2EE.md` (trusted-server section now describes the legacy mode) when phase 7 lands.

## 15. Alternatives considered

* **Per-member keys (`K_u` wrapped to everyone but the server).** More granular than two lines but every member's key needs its own epoch, rekey flag, wrap table and availability story (a new member waits for each author's phone). Two circle-wide lines give the same server-side confidentiality with one set of wraps and one publisher chain. Rejected.
* **Keep one key, hide opt-out by not uploading.** Loses the E2EE relay for that member's data to the other phones. Violates requirement 3. Rejected.
* **Server flag per member.** The server could lie or be compelled to flip it, and an admin could use it as coercion. Rejected: the lane lives in the key the sender uses.
* **Do nothing, tell opted-out members to leave.** Fails requirements 1 and 3.
* **Option (b)/(c) as primary** (section 9): rejected for mobile OS reasons and forgeability.

## 16. Owner decisions (2026-11-07)

Open questions Q1 to Q7 are resolved with the recommendations above: Q1 places follow the creator's lane; Q2 the admin map shows phone-only members as "keeps data on phone"; Q3 pairing-time choice only, no remote override; Q4 phone-only results stay in the member's lane; Q5 home hub is documented only; Q6 no backfill of past history in v1; Q7 stale members may be removed so server assistance can be enabled.

## 17. Phase 1 API (implemented: crypto and wire formats only)

Go: `backend/internal/e2ee/lanes.go`. Dart: `app/lib/services/e2ee/e2ee_crypto.dart` (`E2ee.*`, same names in lowerCamelCase). Shared vectors: `backend/internal/e2ee/testdata/lanes.json` (Go generates with `UPDATE_VECTORS=1 go test ./internal/e2ee -run Lanes`; Dart test `app/test/services/e2ee/e2ee_lanes_test.dart` reads the same file). Legacy `testdata/vectors.json` and `testdata/server_consent.json` are unchanged and still verified.

Values: `Line` / lane = `0x00` phone, `0x01` server (`LinePhone`, `LineServer`; names `"phone"`, `"server"`; `ParseLine`). Unknown line, version, generation 0, or unknown `member_opt_out` is rejected everywhere (fail closed). New log action codes: `ActProcessingPref = 10`, `ActProcessingPolicy = 11` (`LogActionMessage`/`VerifyLogSlice` now accept them).

Wire formats (frozen by the vectors):

* v2 payload: `0x02 || line || gen(4 BE) || nonce(24) || ct || tag`. AEAD key = HKDF-SHA256(key, salt = circle||line||gen, info = `"OFE2EE3-MSG-KEY\0"||purpose`). AAD = `"OFE2EE3-ITEM-AAD\0"||circle||line||gen||device_id||purpose`. Inner envelope (padded as v1): `0x02 || seq(8) || ts_ms(8) || sig(64) || body`. Signature input: `"OFE2EE3-ITEM\0"||circle||line||gen||device_id||len(purpose)(1)||purpose||seq||ts_ms||body`.
* v3 wrap: same sealed-box blob as v1. AAD = `"OFE2EE3-WRAP-AAD\0"||line||circle||gen(4)||recipient||wrapper`. Wrapper signs `"OFE2EE3-WRAP-SIG\0"||(AAD fields after the domain)||blob`. Server-line wraps MUST use v3; legacy phone-line wraps keep `WrapAAD` v1 and stay valid.
* SK commitment: `KeyCommitmentLine` = HKDF(key, salt = circle||line||gen, info = `"OFE2EE3-KEY-COMMIT\0"`, 32).
* `processing_pref` / consent: `"OFE2EE3-PROCESSING\0"||circle||user||lane(1)||sk_gen(4)||server_device_id||server_fingerprint(32)||nonce(16)`. Lane server needs `sk_gen >= 1`, a real server device and a non-zero fingerprint; lane phone needs the zero UUID and an all-zero fingerprint.
* `processing_policy`: `"OFE2EE3-POLICY\0"||circle||admin_user||server_assist(1)||default_for_new(1: lane)||member_opt_out(1: 0 allowed, 1 required_server)||sk_gen(4)||commitment(32)||nonce(16)` (section 16.1). `required_server` requires `server_assist = on`; assist on requires `sk_gen >= 1` and a non-zero commitment.
* Log entry for both statements: `LogActionMessage(action, user, actor_device, circle, subject, sk_gen as epoch, ProcessingRef(statement))`, where `ProcessingRef` = SHA-256 of the statement and `subject` = server device id for a lane-server pref, empty otherwise. A pref's `effective_seq` is the log entry's own seq (chain position), not a signed field.

Exported Go functions (Dart equivalents are static methods on `E2ee`; value types `PayloadHeader`, `ItemV2`, `LineWrap`, `PrefEntry`, `LaneVerdict`, `RollbackGuard`):

```go
func ParseLine(s string) (Line, error)
func ParseMemberOptOut(s string) (MemberOptOut, error)           // "allowed" | "required_server"
func WrapAADLine(circleID string, line Line, gen uint32, recipientDeviceID, wrapperDeviceID string) ([]byte, error)
func WrapSigMessageLine(circleID string, line Line, gen uint32, recipientDeviceID, wrapperDeviceID string, blob []byte) ([]byte, error)
func VerifyWrapSignatureLine(wrapperEdPub []byte, circleID string, line Line, gen uint32, recipientDeviceID, wrapperDeviceID string, blob, sig []byte) error
func KeyCommitmentLine(key []byte, circleID string, line Line, gen uint32) ([]byte, error)
func OpenWrapLine(circleID, deviceID string, xSecret, xPub []byte, w LineWrap, wantLine Line, wantGen uint32, commitment []byte) ([]byte, error)
func CheckWrapRecipient(line Line, recipientKind string, policyOn, hasServerLaneMember bool) error // CK never to kind "server"
func ParsePayloadHeader(payload []byte) (PayloadHeader, error)  // v1 -> phone line, gen = epoch
func SealWithNonceV2(key []byte, circleID string, line Line, gen uint32, deviceID, purpose string, plaintext []byte, nonce [24]byte) ([]byte, error)
func OpenV2(key []byte, circleID string, expectLine Line, deviceID, purpose string, payload []byte) ([]byte, PayloadHeader, error)
func ItemAADV2(...) []byte
func ItemSignedMessageV2(circleID string, line Line, gen uint32, deviceID, purpose string, seq, tsMs uint64, body []byte) ([]byte, error)
func SealItemV2(key []byte, circleID string, line Line, gen uint32, deviceID string, priv ed25519.PrivateKey, purpose string, seq, tsMs uint64, body []byte, nonce [24]byte) ([]byte, error)
func OpenItemV2(key []byte, circleID string, expectLine Line, deviceID string, senderEdPub []byte, purpose string, serverSeq uint64, payload []byte) (ItemV2, error)
func ProcessingPrefMessage(circleID, userID string, lane Line, skGen uint32, serverDeviceID string, serverFingerprint, nonce []byte) ([]byte, error)
func VerifyProcessingPref(approverEdPub []byte, circleID, userID string, lane Line, skGen uint32, serverDeviceID string, serverFingerprint, nonce, sig []byte) error
func ProcessingPolicyMessage(circleID, adminUserID string, serverAssist bool, defaultForNew Line, optOut MemberOptOut, skGen uint32, commitment, nonce []byte) ([]byte, error)
func VerifyProcessingPolicy(adminEdPub []byte, circleID, adminUserID string, serverAssist bool, defaultForNew Line, optOut MemberOptOut, skGen uint32, commitment, nonce, sig []byte) error
func ProcessingRef(statement []byte) []byte
func NewRollbackGuard() *RollbackGuard   // Observe(line, gen, nowMs), Check(line, gen, deviceID, itemTsMs, nowMs): per-line rollback rule
func ClassifyItemLane(prefs []PrefEntry, line Line, itemTsMs uint64) LaneVerdict // flags server-line items from authors without a server pref
```

Caller duties the library does not do: sender approval and registration chain (`Trust.AuthorizeSender`), signed-time window, replay window, verifying that the policy/epoch record is in the verified log (pass its commitment to `OpenWrapLine`), checking the policy signer is a circle admin, `RollbackGuard.Check` only after AEAD and signature succeeded, and the DB-side rules of section 5.4/6.

Vector file format (`lanes.json`, hex strings, `line`/`lane` as 0/1): top-level `circle_id`, `ck_hex`, `sk_hex`, identities `sender`, `admin`, `recipient` (`user_id`, `device_id`, `ed_seed_hex`, `ed_pub_hex`, `x_secret_hex`, `x_pub_hex`), `server_device_id`, `server_fingerprint_hex`; positive arrays `items`, `wraps`, `prefs`, `policies` (inputs plus expected `payload_hex` / `blob_hex` / `message_hex` / `sig_hex` / `commitment_hex` / log ref and log action message); and `negative.{items,wraps,prefs,policies}`: each entry has the inputs of the verifying function and MUST be rejected. Negative coverage: line or gen tampered in header, CK payload or wrap replayed as SK (signature replay, re-signed with v3 AAD, re-signed legacy v1 AAD), identical key bytes relabelled across lines, signature made for the other line inside a server payload, unknown line/version, wrong sender/device/purpose/seq, wrong or short commitment, consent moved across circle/user/gen/lane/nonce/server device, wrong server fingerprint, legacy consent signature offered as new, policy field flips including `member_opt_out` and unknown `member_opt_out`.

