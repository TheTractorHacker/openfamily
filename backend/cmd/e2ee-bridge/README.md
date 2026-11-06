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
`4` key log verification failed, `5` OpenFamily login expired (re-run `enroll --email ...`), `6` Dawarich refused the API key.

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
