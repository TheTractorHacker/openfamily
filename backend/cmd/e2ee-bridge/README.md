# e2ee-bridge: Private circles to your own Dawarich

`e2ee-bridge` exports the positions of **Private (end-to-end encrypted)** OpenFamily
circles to your own [Dawarich](https://dawarich.app) without the OpenFamily server
ever seeing a plaintext coordinate. (The built-in Dawarich export cannot work for a
Private circle because the server cannot read the positions; see `docs/design/E2EE.md`.)

The bridge is a `service` **device member** of the circle: it has its own Ed25519 and
X25519 keys, your phone approves it and wraps the circle keys for it, and it decrypts
and verifies items exactly like a phone does. The plaintext leaves the bridge only
towards the Dawarich URLs you configure.

## Run it OFF the OpenFamily server host

**Whoever runs this program can read every position of the circles it joins.** The whole
point of a Private circle is that the OpenFamily server cannot. If you run the bridge on
the same machine (or the same account, or a backup that the server operator controls)
as the OpenFamily server, the operator can read the bridge's key file and the circle
becomes readable again. Run it on a machine you control and that the server operator does
not: a home server, a NAS, a Raspberry Pi. `--help` says the same.

## Trust model

* The OpenFamily server is the adversary. The bridge verifies what the server tells it the way
  the phone does (`internal/e2ee/verify.go`, mirroring the Dart `verifyRegistration`,
  `verifyLogSlice`, `syncCircleKeys`, `ChannelReceiver`):
  * the **key transparency log** (`GET /e2ee/log`, hash chain from the genesis hash, signatures,
    redacted entries, a pinned head that survives restarts, rollback / fork / gap detection).
    On any log problem the bridge **stops** (exit code 4) and says so loudly;
  * every **wrap**: wrapper signature, the epoch record's publisher signature, AEAD with the
    circle/epoch/recipient/wrapper AAD, and the key commitment recomputed from the unwrapped key must equal
    the commitment the publisher signed. Additionally, if the wrapper or the epoch's publisher is a key the circle
    state lists, the public key carried by the wrap/record must be that key;
  * every **item**: AEAD, the signed `seq` equals the relayed `seq`, the sender device is in
    `members[].devices[]`, `approved: true`, not `recovery`, its registration chain verifies, and the
    Ed25519 item signature verifies. Duplicates are dropped by a per-device window (512) and high-water mark,
    signed times more than 10 minutes in the future are refused, and the epoch-rollback rules of the phone apply.
* It does **not** make a hostile server harmless: a server can withhold or delay items, and (like for the
  phones) a never-verified person's key is trusted on first use. See "Honest limits" in the E2EE design doc.
* Secrets on disk: identity seed, circle keys and the OpenFamily refresh token are in `0600` files in a
  `0700` directory, written atomically; set a passphrase (`E2EE_BRIDGE_PASSPHRASE` or `--passphrase-file`)
  to seal them with Argon2id (64 MiB, 3 passes) + XChaCha20-Poly1305. Access tokens are never written.
  The bridge never logs keys, coordinates, tokens or passwords (log lines carry counts only; a test scans the log output).
  The Dawarich API keys live in your config file (keep it `0600`).

## Enrolling (two steps)

1. On the bridge host (the password is read from `E2EE_BRIDGE_PASSWORD` or one line of stdin, never from arguments):

   ```
   e2ee-bridge enroll --server https://family.example.org --email you@example.org [--totp 123456] [--name "Dawarich bridge"]
   ```

   It creates the key, logs in (only the rotating refresh token is stored), and prints the name, the short
   fingerprint, the 12x5 digits and the **REQUEST CODE** (padded base64url of the key-binding JSON).
2. On your phone: *Encryption keys > Approve a viewer or bridge*, paste the request code, compare the digits with the
   ones printed by the bridge, approve. The phone shows an **APPROVAL CODE**.
3. On the bridge host:

   ```
   e2ee-bridge enroll --approval <APPROVAL CODE>
   ```

   This registers the key (`POST /e2ee/devices`, kind `service`, read-only: `can_upload:false`).
4. Open the circle's encryption screen on your phone once: it wraps the circle keys for the bridge
   (the bridge keeps polling with a backoff of 30 s up to 10 min until the wrap exists).

If the key must be approved by a circle admin first (the usual approval rule for replacement keys), the circle
admin approves it in the app; the bridge simply gets `403 no_approved_device` until then.

## Running

```
e2ee-bridge run --config config.json [--once]
e2ee-bridge status
e2ee-bridge revoke
```

`run` polls every `poll_seconds` (default 30): refreshes each private circle's state, verifies the log, syncs keys,
pulls `GET /circles/{id}/e2ee/items?after=<cursor>&as_device=<bridge>&purpose=fix,history&limit=500` and pushes
to Dawarich. SIGINT/SIGTERM finish the page in progress, persist the state and exit 0. (It does not subscribe to
`/ws/stream`; polling every 30 s is enough for an export.)

Exit codes: `0` ok / clean shutdown, `1` error, `2` usage or config, `3` the server answered
`403 no_approved_device` (bridge revoked, or its key is no longer approved: it stops, it never loops),
`4` key log verification failed, `5` OpenFamily login expired (re-run `enroll --email ...`), `6` Dawarich refused the API key (server mode: the ingest token), `7` security alarm in a lanes circle (see "Lanes circles").

`status` prints the device, fingerprint, registration, pinned log entry, cursors and counters (no secrets, works without the passphrase).
`revoke` revokes the bridge key on the server (`DELETE /e2ee/devices/{id}` signed by the bridge itself); the server drops its
wraps and flags the circle for a new epoch, which an admin phone then publishes. It also wipes the local circle keys and session.

### Configuration

```json
{
  "dawarich": { "base_url": "https://dawarich.example.org", "local_url": "http://192.168.1.20:3000",
                "api_key": "MAIN-KEY", "send_unmapped": false },
  "users": { "<openfamily user id>": { "api_key": "THAT-PERSONS-KEY", "label": "alice" } },
  "circles": [], "since": "2026-01-01", "poll_seconds": 30
}
```

* `users`: per-person Dawarich account. People without an entry go to the main key only if `send_unmapped` is true,
  otherwise their points are dropped (counted as `unmapped_user`).
* `circles`: restrict to these circle ids (empty: every private circle you are in).
* `since`: never send points older than this.
* `E2EE_BRIDGE_DAWARICH_KEY` overrides `dawarich.api_key`. The config is the bridge's own file; the OpenFamily server never sees it.
* `local_url` is tried when `base_url` is unreachable (as in the server's own export).

A full example is in `deploy/e2ee-bridge/config.example.json`.

### Dawarich mapping

Same as the server's export (`backend/internal/handlers/dawarich.go`): `POST {base}/api/v1/points`,
`Authorization: Bearer <key>`, body `{"locations":[GeoJSON Feature]}` in batches of 500, geometry `[lon, lat]`,
properties `timestamp` (RFC3339 UTC, the sender's signed time), `device_id` (the member's name), `unique_id` (the sender device id),
`horizontal_accuracy`, `altitude`, `speed`, `battery_level` (= battery percent / 100). History chunks become points (time, lat, lon, accuracy).
Latitude/longitude are range-checked; invalid points are skipped.

### Duplicates

* A per-sender-device high-water mark of delivered points (persisted after each successful batch): a point with a
  time not newer than it is not sent, so a live fix and the later history chunk covering it never duplicate (the same point arriving via two
  circles is also covered). Within one pull, live and history points are merged by time first.
* Before the first send after each start, per Dawarich account, the bridge asks Dawarich for its newest existing point
  (`GET /api/v1/points?start_at=&end_at=&per_page=1&order=desc`, same key) and never sends points not newer than it
  (for that member name when Dawarich reports one, otherwise only for dedicated per-person accounts). Failure is "unknown" and local state is relied on.
* The cursor per circle is persisted only after a page was fully handled and delivered. If Dawarich is down the page is
  re-processed later; nothing is lost and, thanks to the high-water mark, nothing is sent twice.
* Items whose epoch key or sender record are not known yet are **deferred**: the cursor does not pass them and they are retried (keys: exponential
  backoff 30 s to 10 min; an unknown sender: 15 minutes, then dropped; a missing key: 7 days).

## Docker

```
docker build -f deploy/e2ee-bridge/Dockerfile -t e2ee-bridge .
docker run --rm -it -v bridge-state:/state e2ee-bridge --help
```

See `deploy/e2ee-bridge/docker-compose.example.yml` for a full enrol-and-run walk-through (distroless, non-root, read-only
root file system, state volume, passphrase as a Docker secret).

## Limits (honest)

* The bridge can only read what its own key can: it holds the circle keys it was given and sees only items the server still
  stores (48 h for live fixes, the sender's retention for history). Points from **senders whose key was revoked before the bridge
  looked** cannot be shown: the circle state lists only active keys, so their items fail the sender check and are dropped.
* History points older than what was already delivered for that device are not sent (the price of never duplicating); a live fix that arrives out of order after a newer one
  from the same device in an earlier page is likewise skipped.
* A hostile or compromised server can withhold or delay items and cannot forge them, but the bridge cannot detect a *split view* of the log.
* The Dawarich API assumptions (the `/api/v1/points` POST payload and the newest-point query shape) follow the server's existing
  export and the public Dawarich API; they have **not been verified against a live Dawarich**, nor has the whole bridge been run against a real OpenFamily server (tests use fakes with real cryptography).
* Only one bridge process per state directory (no lock file).
* The wire formats are not externally audited; see the E2EE design doc.

## Server mode: the OpenFamily server as a trusted member

`e2ee-bridge` can also be the **OpenFamily server's own device** (`enroll --kind server`, `"mode": "server"`
in the config). Instead of Dawarich it hands the decrypted, verified positions to the OpenFamily API
(`POST /internal/e2ee/ingest`, authenticated by `E2EE_SERVER_INGEST_TOKEN`, shared only with the API) so the server's map,
history, geofencing and built-in Dawarich sync work for the circles whose members all consented. **Here, unlike
the Dawarich mode above, running it next to the server is the point** and the server host can read those circles.
Read "Trusted-server mode" in `docs/design/E2EE.md` first. It reads a circle only after it verified, against the key
log, a phone-signed consent from every member of that circle.

Enrollment with the compose service (profile `e2ee-server`; the key stays in the `e2ee_server_state` volume, never in Postgres):

```
export E2EE_SERVER_INGEST_TOKEN=$(openssl rand -hex 32)   # put it in .env; the API and the sidecar both read it
docker compose --profile e2ee-server up -d api
docker compose --profile e2ee-server run --rm -T e2ee-server-device enroll --kind server \
    --server http://api:8080 --email you@example.org < password.txt
# prints name "OpenFamily server" + fingerprint + REQUEST CODE; approve it on your phone
# (Encryption keys > Approve a viewer or bridge), compare the digits, then:
docker compose --profile e2ee-server run --rm e2ee-server-device enroll --approval <APPROVAL CODE>
docker compose --profile e2ee-server up -d e2ee-server-device
```

Then in each circle every member opens *Encryption keys > circle > Trusted server* and allows it, and a circle admin
taps *Give the server the circle key*. Revoke with `e2ee-bridge revoke` (or from a phone); delete the server's plaintext copies
from the same app screen. Exit code 6 in this mode also covers a refused ingest token.

## Lanes circles (per-member processing lanes)

Circles with per-member lanes (`docs/design/PRIVACY_PROCESSING.md`) change what both modes read. Detection is
cryptographic, not a server flag: once the verified key log contains a `processing_policy` for a circle, the
sidecar fetches `GET /circles/{id}/e2ee/processing` and the policy statement it serves must be the NEWEST policy
entry of that log, signed by a device of a current circle admin; otherwise the circle is **not read** (a warning
is logged). A circle whose log has no policy keeps the old flow described above (legacy trusted-server circle, or
the Dawarich bridge's CK flow), unchanged.

When the verified policy has server assistance **on**:

* The device holds **only the server key SK**. It asks `GET .../wraps?key_line=server` and never asks for, stores or
  opens a circle key (CK). Each SK wrap must come from a device of the admin who signed that generation's policy,
  and the unwrapped key must match the policy's signed commitment. **If the server answers that request with a
  phone-line (CK) wrap, or an SK that is byte-identical to a CK or has the commitment of a CK epoch, the device
  logs `SECURITY ALARM`, stores nothing and exits with code 7.**
* It pulls only `key_line=server`, purposes `fix,history`, with its own cursor (`status` shows "server line").
  Result items (`trip`, `drive`, `week`) are never requested: the server computes its own from the ingested fixes
  (ADR 8.4), and results of phone-lane members are not readable by the server by design.
* **Per author lane check, before any decryption:** an item is opened only if its author's lane is VERIFIED
  `server`: the member's signed `processing_pref` must be their newest one in the verified key log, signed by a
  usable phone key of that member, naming exactly this server key (the sidecar's own key; for the Dawarich bridge
  the pinned key from `GET /e2ee/server-device`), with `sk_gen` within the policy's generations. Phone-lane members,
  members without a statement, replayed old statements and unlogged statements are counted as
  `deferred_author_not_server_lane` (retried for 15 minutes in case the member's statement is just about to arrive, then
  dropped as `author_not_server_lane_expired`); their ciphertext is never decrypted (the sidecar could not read it anyway).
  With nobody in the server lane the circle is not pulled at all.
* Per item, additionally: v2 header (line = server, generation = declared epoch), AEAD under SK of that generation,
  the author device authorization chain, signature, seq, signed-time window, the replay window, and the **per-line
  rollback rule** (`RollbackGuard`, persisted in `state.json`; a newer SK generation never outdates CK). A phone-line
  or v1 payload relayed as server line is rejected as `line_mismatch`.
* **Missing wraps** are reported in the log, once per change: "this device holds no server key for the current
  generation yet; waiting for an admin's phone" (open the circle's encryption screen on an admin phone) and
  "member devices that lack the current server key" with a count (from `.../pending?key_line=server`).
* **Policy off** (verified): the device drops its SK (also from disk) and stops reading that circle; when it held a
  server key and no circle remains readable it exits with code 3. A revoked key stops with code 3 as before
  (`403 no_approved_device`).
* The server still re-verifies every ingested point (policy, member lane, newest log entry) in Go; the sidecar's check
  is an independent second one.
* **Dawarich bridge** (`service` key): in a lanes circle with assistance on it forwards only server-lane members'
  points, using the same engine (`key_line=server`, SK). It does not read the phone line even if its owner gave it a
  CK (ADR 8.9: that is the "includes phone-only data" decision and is not exercised here). A circle without a policy,
  or whose policy is off, keeps the old CK flow. The built-in server-side Dawarich sync reads only the plaintext
  `locations` table, which never holds a phone-lane member's points (test:
  `handlers/e2ee_dawarich_lanes_db_test.go`).

Upgraded legacy circles: the old phone-key epochs stay with the server until the admin calls
`DELETE /circles/{id}/e2ee/legacy-server-access`; this sidecar never uses them (it only asks for the server line),
and a converted legacy consent is honoured only while the member has signed no newer statement.

Exit code 7 is new: a CK wrap offered for the server line, or an SK reusing a CK.
