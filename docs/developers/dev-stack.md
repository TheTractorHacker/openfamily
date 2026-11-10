# Dev stack and end-to-end scenarios

A throwaway Orbitly stack plus real end-to-end scenarios, for when there is no Android emulator, no phone and no
Xcode on the machine (a VM without nested virtualization, for example). Nothing here replaces testing on a real
phone or watch; it covers everything that does not need one: the server, its database, the sign-in and refresh
rules, and the app's own Dart crypto and E2EE client talking real HTTP to the real server.

Docker only. Needs network access the first time (Go toolchain image, modules, the Flutter image). The first image
build takes minutes (about 20 on a heavily loaded host); later starts reuse it. The SQL probe the tests use is built
once into `~/.cache/orbitly-dev-stack` (`DEV_STACK_CACHE`).

## The stack: `scripts/dev/dev-stack.sh`

| Command | What it does |
| --- | --- |
| `up [--build]` | builds the API image from the working tree (first time, or with `--build`) and starts API + Postgres |
| `seed` | owner, two family members and a Private circle with server processing on, through the real API |
| `reset [--no-seed]` | removes the volumes and secrets, starts fresh, seeds |
| `down [-v]` | removes the containers; `-v` also removes volumes and the secrets directory |
| `status` | ports, health, image, seeded accounts |

It layers [`scripts/dev/dev-stack.compose.yml`](../../scripts/dev/dev-stack.compose.yml) on the repo's own
`docker-compose.yml`, so the API is built from the same `backend/Dockerfile`, the database is the same pinned
TimescaleDB image with the same `max_connections` (`PG_MAX_CONNECTIONS`, 60) and the API pool size
(`DB_MAX_CONNS`, 15) as production. Differences: `fsync` is off, the built-in server device is forced on, geocoders
and push are off, and the backup service is not started.

It cannot touch production, even on the same host:

- its own compose project name (`orbitly-dev`; the script refuses `openfamily`, `orbitly` and `openfamily-src`), so
  containers and volumes (`pgdata`, `server_device`, `apk_data`) are separate;
- the image is tagged `openfamily-api:devstack`, never the `:local` tag production uses;
- loopback ports picked free at first start (`DEV_API_PORT` / `DEV_DB_PORT` to choose them);
- a freshly generated `stack.env` (database password, JWT secret, owner password) in
  `$TMPDIR/orbitly-dev-stack-<uid>` (`DEV_STACK_DIR`), mode 600; the repo `.env` is never read and `docker compose`
  runs in a clean environment, so an exported production variable cannot leak in.

The owner is the platform admin created at start-up from `PLATFORM_ADMIN_EMAIL` / `PLATFORM_ADMIN_PASSWORD` (in
`stack.env`), because only a platform admin may approve the built-in server key. Members are made through
`POST /api/admin/users`, the circle through `POST /circles`, invites and joins. Making the circle Private, the
server key's approval, the policy and the members' lanes need the app's cryptography, so `seed` runs
`app/test/e2e_dev_stack/seed_test.dart` in the Flutter image. `seed` writes `seed.json` next to `stack.env`.

Limit: the seeding phones are test phones. Their keys live in memory and are gone when `seed` ends. A real phone
that signs in as a seeded account registers its own key; the first key of an account is trusted, a later one needs
approval from an existing key, so for a real device use `reset --no-seed` and create the Private circle from the app.

## The scenarios: `scripts/dev/e2e.sh`

```
scripts/dev/e2e.sh            # fresh stack, every file, stack removed afterwards
scripts/dev/e2e.sh auth       # (a)        scripts/dev/e2e.sh lanes     # (b)(c)(d)
scripts/dev/e2e.sh conn       # (e)        scripts/dev/e2e.sh --keep ...  # keep / reuse the stack
```

It runs its own stack (`orbitly-e2e`), separate from the development stack, streams the API and Postgres container
logs to files the tests read, runs each file with `flutter test` in the Flutter image, then audits the API log (no
phone-lane coordinate, no panic). A plain `flutter test` skips these files (`E2E_DEV_STACK` unset).

| File (`app/test/e2e_dev_stack/`) | Scenarios |
| --- | --- |
| `auth_refresh_test.dart` | **(a)** sign-in (wrong password, unknown account), refresh rotation (spent token, same family), a lost answer retried within the 3 minute window (same successor, audited `auth.refresh_retry`), after the window (`used_at` backdated on the database clock: 401, family revoked, `auth.refresh_reuse`), a retry after the successor was used, the cap of 8 answers per spent token, access tokens versus logout |
| `lanes_stack_test.dart` | **(b)** device key registration, joining, sealed fixes on the phone lane and the server lane, another member pulls and decrypts, the built-in server device stores the server-lane member's fix and never the phone-lane member's. **(d)** `bad_epoch` (both lines), `lane_not_server`, a mixed batch, an unknown device, each with the `e2ee items rejected` log line. **(c)** the owner resets keys on a new phone (an empty key store; on a phone whose key is still active a reset does nothing): devices revoked, the server key replaced (new device id, approved by the owner's phone, re-pinned), wraps of revoked keys deleted, rekey flags set while the epoch is unchanged, the owner's server-lane pref deleted, policy statements kept, policy no longer in effect; uploads refused with `device_revoked` (403, `e2ee upload refused` log line), `device_not_approved`, and per item `lane_not_server` |
| `connections_test.dart` | **(e)** `max_connections` is the explicit 60 (not the image's 25) with room above the pool; 400 concurrent authenticated requests and two more waves: no non-200, no "too many clients" in the answers, the API log or the Postgres log, the peak number of server processes below the limit |

### Expected-failing checks

Checks for features other tracks are still building are written as `expectedFailing(...)` (in
`support.dart`): they run, must fail today, and the run FAILS with "now PASSES" the day the feature lands, which is
the signal to delete the marker and keep the check. `E2E_XFAIL=skip` skips them instead. Today:

| Check | Waiting for |
| --- | --- |
| the server key survives an owner reset (same device id, wraps and the owner's pref intact) | stable server key |
| a member who never opened the app is on the server lane after an admin forces it | forced server processing |
| a reinstalled app (empty key store) gets its device identity back without a new key | reinstall restore |

The last two are placeholders: they assert the observable outcome with today's building blocks, and need to be
updated to the final API when those features exist.

### Things to know when writing scenarios

- **Per-IP rate limits.** The auth limits (login 20, register 5 per hour, refresh 60, join 10 per 15 minutes) are
  in memory and keyed on the client address. The stack trusts `X-Forwarded-For` from the Docker bridge, so every
  simulated phone sends its own public-looking address (`203.0.113.x`, `198.51.100.x`, `192.0.2.x`, via `nextIp()`;
  a `10.x` address would be skipped as a proxy). Accounts are made through the admin API, not `/auth/register`.
  Restarting the API (`dev-stack.sh restart-api`) resets the limiter.
- **One server key per server.** The built-in device has one key, owned by whoever approved it. The lanes scenario
  needs it unapproved, so `e2e.sh` starts from a fresh stack; `--keep` only helps for `auth` and `conn`.
- **Waiting.** The built-in device polls every 15 s; scenarios wait with deadlines, not fixed sleeps. Approving the
  server's key writes its identity file and fsyncs it before answering; on a busy disk that can exceed the app's 15
  second request limit (seen on a loaded shared host). `addServerThroughApp` does what a person would: it waits
  for the server to finish and taps OK again.
- **Key resets** only revoke keys when the resetting phone has no active key of its own (a new phone, a
  reinstall without restore). The scenario therefore resets from a second phone object with an empty key store.
- **Time windows** are tested by writing `refresh_sessions.used_at` through the SQL probe (`Db.exec`), not by waiting.
- **Refusal items are crafted.** The server checks device state, epoch and lane before it looks at the ciphertext,
  so `craftItem` (valid header, random body) is enough to provoke `bad_epoch` and `lane_not_server`; genuinely
  sealed items are used wherever the content matters.
- The harness is `app/test/e2e_real_server/harness.dart`, shared with `scripts/e2e-lanes.sh` (see
  [E2E lanes](../testing/E2E_LANES.md)); that older rig runs a bare `go build` binary with `APP_ENV=development`
  and its own Postgres without the production limits, which is why scenario (e) lives here.

## What this does not prove

Nothing here runs on a real phone, a watch, an Android emulator or Xcode: no OS background limits, battery, push,
platform keystores, UI. It proves the server and the shared Dart logic against each other.
