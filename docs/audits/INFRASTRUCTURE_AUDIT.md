# OpenFamily Infrastructure Audit

Branch `audit/baseline` (HEAD 6b6968c). Date 2026-10-25. Scope: read-only static review of compose, Dockerfiles, Caddy, updater, CI workflows, migrations, config, upstream references, licenses. No containers were started, nothing was built, and no network lookups were made. Anything depending on runtime behaviour or on upstream GitHub settings is marked "needs verification".

## 1. Findings table

| ID | Severity | Area | Title | Effort |
|---|---|---|---|---|
| INF-001 | Critical | Updater | Docker socket mounted in a root container by default, even when updates are disabled | M |
| INF-002 | High | Updater | Malicious or compromised upstream commit gives root on the host (unsigned `git pull` then `compose build/up`) | L |
| INF-003 | High | Updater | Updater mounts the whole repo read-write, including `.env` secrets, as root | S |
| INF-004 | High | Backup | No backup, restore, or pre-update snapshot tooling; no rollback after failed update or migration | M |
| INF-005 | High | Supply chain | APK served to families is fetched from `wheresfrank/openfamily` releases with no checksum or signature verification | M |
| INF-006 | High | Containers | API and updater run as root; no cap_drop, read_only, no-new-privileges, or resource limits on any service | M |
| INF-007 | Medium | Images | No base image digests; `ntfy:latest`, `caddy:2-alpine`, `timescaledb-ha:pg16` float | S |
| INF-008 | Medium | Config/TLS | Production mode is unusable out of the box: compose forces `sslmode=disable` unless the operator also enables Postgres TLS | M |
| INF-009 | Medium | Defaults | Default install uses published-in-repo credentials (`POSTGRES_PASSWORD=openfamily`/`change-me`) and APP_ENV=development, which skips the DB checks | S |
| INF-010 | Medium | Network | ntfy has no auth or access control when exposed via `Caddyfile.with-push`; Caddy has no security headers | S |
| INF-011 | Medium | Updater | Update-source mismatch: "update available" is computed from `APK_GITHUB_REPO`, but the updater pulls from the clone's `origin` | S |
| INF-012 | Medium | CI | Actions pinned to mutable major tags; `test.yml` and `web-preview.yml` have no `permissions:` block; apk.yml has `contents: write` at workflow level | S |
| INF-013 | Medium | Migrations | Startup auto-migrate with no pre-backup; failed migration leaves a dirty state; 000012 backfills with a full hypertable scan | M |
| INF-014 | Medium | Database | No compression policy, fixed 90-day retention, redundant/heavy indexes on the hypertable | M |
| INF-015 | Low | Updater | Token compared non-constant-time, no rate limit, `/status` unauthenticated; `UPDATE_BRANCH` not validated as a ref | S |
| INF-016 | Low | Compose | Missing healthchecks (caddy, ntfy, updater); `caddy` depends on `api` without health condition; Caddyfile.with-push breaks if `PUSH_ADDRESS` is empty | S |
| INF-017 | Low | Database | Pool hard-coded to `MaxConns=10`, no lifetimes or timeouts; HTTP server has only `ReadHeaderTimeout` | S |
| INF-018 | Low | Upstream | 70+ `wheresfrank` references (module path, repo default, analytics, docs, site) to rebrand | M |
| INF-019 | Low | Docs | Docs drift: self-hosting says a commented ntfy block exists in `caddy/Caddyfile` (it does not); docs/custom-domain.md link points at a different repo (`whereabouts`) | S |
| INF-020 | Low | Licensing | AGPL-3.0 project; vendored `background_locator_2` (MIT); no third-party license inventory or SBOM; committed built web assets | M |
| INF-021 | Info | CA trust | eMudhra distrust is correct and tested, but is a time-boxed incident control now embedded in four Dockerfile stages | S |
| INF-022 | Info | Checked OK | Items checked and fine (see section 10) | - |

---

## 2. Container and compose review (scope 1)

### INF-001 Docker socket in a default-on root container (Critical)
Evidence: `docker-compose.yml:151-173` (`updater` service, `/var/run/docker.sock:/var/run/docker.sock` at line 168), `updater/Dockerfile` has no `USER`, so root. The service is always started by `docker compose up`, whether or not `UPDATER_TOKEN` is set (line 154 defaults to empty; the comment at lines 146-149 says empty "disables updates", but only the HTTP endpoint is disabled, the socket stays mounted).
Failure scenario: any code execution inside the updater container (a vulnerability in `main.go`, a malicious dependency in the alpine `git`/`docker-cli` packages, a compromised image rebuild) equals root on the host: `docker run -v /:/host --privileged`. Operators who never use the button still carry this risk.
Fix: move `updater` behind a compose profile (`profiles: ["self-update"]`) so it is opt-in; better, remove it entirely per the replacement design in section 3.5. Until then, put a socket proxy (e.g. a read/limited-API filter such as tecnativa/docker-socket-proxy, needs verification that it permits the `compose up` calls used) in front.
Effort: M. Acceptance: `docker compose up -d` on a fresh clone starts no container with the Docker socket; `docker ps --format '{{.Mounts}}'` shows no `docker.sock`.

### INF-006 No container hardening (High)
Evidence: no `user:`, `read_only`, `cap_drop`, `security_opt`, `mem_limit`/`deploy.resources`, `pids_limit` anywhere in `docker-compose.yml`. `backend/Dockerfile:36-43` runtime stage has no `USER`; the API binary runs as root in alpine. The API only needs to write `/data/apk` and `/data/deploy` (compose lines 95-96).
Failure scenario: an RCE in the API (e.g. via the admin `flutter build` exec at `backend/internal/handlers/admin_apk.go:225`, or a dependency flaw) gets root in the container with all default capabilities and unbounded memory/CPU (a location flood can OOM the host).
Fix: add `adduser -S app` and `USER app` to the runtime stage, `chown` `/data`; compose: `read_only: true` with `tmpfs: [/tmp]`, `cap_drop: [ALL]`, `security_opt: ["no-new-privileges:true"]`, `mem_limit`, `cpus`, `pids_limit` for api, caddy (needs `NET_BIND_SERVICE` only), ntfy. Postgres: set `shm_size` and a memory limit.
Effort: M. Acceptance: `docker compose exec api id` is non-root; `docker inspect` shows CapDrop ALL, ReadonlyRootfs true, Memory set; full smoke test (login, location post, APK cache write) passes.

### INF-007 Image pinning (Medium)
Evidence: `docker-compose.yml:10` `caddy:2-alpine`; `:109` `timescale/timescaledb-ha:pg16`; `:124` `binwiederhier/ntfy:latest`; `backend/Dockerfile:2,36` `golang:1.27.3-alpine`, `alpine:3.22`; `updater/Dockerfile:2,13` same. No digests. Positive: the Go version is pinned to a patch release, and CI uses `docker build --pull`.
Failure scenario: `ntfy:latest` can change behaviour or config format on any rebuild/pull; a compromised tag is picked up silently, and `--pull --no-cache` in the documented CA procedure maximises exposure.
Fix: pin `image: name:tag@sha256:...`; let Dependabot/Renovate bump digests (there is no `.github/dependabot.yml` in the tree; only `workflows/` exists in `.github`, though git log shows dependabot-style commits, so it may be configured at the repo settings level, needs verification).
Effort: S. Acceptance: every `image:`/`FROM` has a digest; a bot PR bumps them.

### Multi-stage builds, healthchecks (checked)
- Multi-stage: yes for api (`backend/Dockerfile`) and updater, static `CGO_ENABLED=0` binaries, `-trimpath`, stripped. Good.
- Healthchecks exist for api (`docker-compose.yml:102-106`, busybox wget to `/healthz`, correct `$$` escaping) and postgres (`:117-121`). Missing for caddy, ntfy, updater (INF-016).
- Build context hygiene: `backend/Dockerfile.dockerignore` is an allowlist (`*` then re-includes), copying only `backend`, `.git/HEAD`, refs, packed-refs, and the CA script. Good: `.env` is not in the build context.

### INF-008 TLS to Postgres (Medium)
Evidence: `docker-compose.yml:40` builds `DATABASE_URL` with `sslmode=disable` when `DATABASE_URL` is unset. `backend/internal/config/config.go:224-230` rejects `sslmode=disable` and the default URL when `APP_ENV=production`. The `timescaledb-ha` image does not ship a server certificate configured by default (needs verification).
Failure scenario: an operator sets `APP_ENV=production` per the docs, API refuses to start; the fastest fix is to set `DATABASE_URL=...sslmode=require` which fails unless Postgres is also configured with `ssl=on` and certs, or to switch back to `development`, which turns the check off. Result: production-labelled deployments either break or silently run without the check. Traffic is on the private compose network, so real exposure is low unless Postgres is later published or moved to another host.
Fix: ship a documented Postgres TLS recipe (cert generation script, `-c ssl=on` command, mounted certs) and make `sslmode=require` the compose default for production; or explicitly document that intra-compose `sslmode=disable` with APP_ENV=production needs an allow flag such as `DB_SSL_DISABLE_OK=true`. Also the substring check `strings.Contains(..., "sslmode=disable")` misses the key-value DSN form and `sslmode=prefer`/`allow`; parse the URL and require `require|verify-ca|verify-full`.
Effort: M. Acceptance: fresh `APP_ENV=production` install following the docs starts; `show ssl` returns on; unit test covers `sslmode=allow/prefer/disable` rejection.

### INF-009 Default credentials (Medium)
Evidence: `docker-compose.yml:41,113` fallbacks `change-me-in-production` (rejected by config validation, config.go:221) and `openfamily`; `.env.example:21,25` `POSTGRES_PASSWORD=change-me`, `JWT_SECRET=change-me-in-production`, `APP_ENV=development` (line 49). JWT is protected by `Validate` (min 32 bytes, rejects the placeholder), checked OK. The DB password has no validation anywhere.
Failure scenario: Postgres is not published, so the exposure is lateral (another container, ntfy compromise) and via backups/logs. Still, `change-me` is accepted forever.
Fix: add `scripts/init-env.sh` that generates `.env` with `openssl rand`; fail startup in production if the DB password in `DATABASE_URL` equals `openfamily`/`change-me`; use `${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}` in compose to require it.
Effort: S. Acceptance: `docker compose up` without `POSTGRES_PASSWORD` errors with a clear message.

### INF-010 Network exposure, Caddy, ntfy (Medium)
Evidence: published ports are `80`, `443` (caddy, lines 12-14) and `127.0.0.1:2586:80` (ntfy, line 138): loopback-only, confirmed, good. api, postgres, updater use `expose`/nothing, good. `caddy/Caddyfile.with-push:14-17` proxies ntfy to the internet with no auth: ntfy default is `auth-default-access: read-write`, no `NTFY_AUTH_*` env, no rate limit config (needs verification against the pinned ntfy version). `caddy/Caddyfile` has only `encode gzip`/`reverse_proxy`: no HSTS, no `X-Content-Type-Options`, no request body limit, no timeouts. Default `SITE_ADDRESS=:80` (compose line 17) plus `TLS_BEHIND_PROXY=true` default (line 49) means a default install happily serves location data over plain HTTP with no warning.
Failure scenario: anyone can publish to or subscribe to any topic on the public ntfy host (topic names are the only secret); spam, or reading notification metadata if topic names leak. A user who forgets to set `SITE_ADDRESS` exposes cleartext location data on port 80.
Fix: ntfy `server.yml` with `auth-default-access: deny-all`, a user for the API, and use access tokens in the registered UnifiedPush endpoints (needs client verification, UnifiedPush endpoints are usually anonymous topics, so alternatively keep read-write but add `visitor-request-limit-*` and `enable-login: false`). Caddy: add `header { Strict-Transport-Security ...; X-Content-Type-Options nosniff; -Server }`, `request_body { max_size 12MB }`. Warn loudly in the API when `SITE_ADDRESS` is `:80` and `APP_ENV=production`.
Effort: S. Acceptance: `curl -I https://host` shows HSTS; ntfy publish without token to a non-allowlisted topic fails or is rate limited.

### INF-016 Smaller compose issues (Low)
- `docker-compose.yml:26-27` `caddy.depends_on: api` has no `condition: service_healthy`; Caddy may serve 502s during start.
- `caddy/Caddyfile.with-push:14` `{$PUSH_ADDRESS}` with an empty value is an invalid site block; the file is only safe if PUSH_ADDRESS is set (compose defaults to empty). Use `{$PUSH_ADDRESS:push.invalid}` or document.
- `${REPO_DIR:-.}/apk:/data/apk` (line 95) is a bind mount for a runtime cache; a named volume would avoid host-path coupling (this coupling is the cause of two logged production incidents in `updater/main.go:291-297, 319-324`).
- No logging driver limits (`logging: options: max-size`): json-file logs grow unbounded.
Effort: S.

---

## 3. Updater sidecar threat model (scope 2)

### 3.1 What it does (updater/main.go, 666 lines)
HTTP server `:8081` (line 44, internal network only). Routes (lines 109-115): `GET /healthz`, `GET /status` (no auth), `POST /apply` (token), `GET /log` (token). `/apply` starts a goroutine (`run`, line 245): `git fetch origin`, `git checkout <branch>`, `git merge --ff-only origin/<branch>` (lines 559-578), resolves the host path of its `/repo` mount via `docker inspect` (498-516), `docker compose build` (311), `docker compose up -d --build --no-deps <all services but updater>` (357-375), then if its own image changed starts a detached bootstrap container with the socket and repo mounted to `compose up -d updater` (451-459). State in `/data/update-state.json`, log in `/data/update.log`.

### 3.2 Trust boundaries and attack paths

| Actor | Capability today | Result |
|---|---|---|
| Unauthenticated container on the compose network (ntfy, caddy, postgres, api) | `GET /status` (main.go:194, leaks current git ref, busy flag, job error text). `/apply` and `/log` need the token | Information only. Any compromised container can probe; if `UPDATER_TOKEN` is empty, `authorized()` (line 239) returns false for everything, so fail-closed. Good. |
| Compromised API (has `UPDATER_TOKEN`, `backend/internal/handlers/admin_update.go:133,177,200`) | Can call `/apply` and `/log`. `/apply` takes no body or parameters (main.go:213-236), so the API cannot choose a branch, ref, or command | Can force an update to whatever `origin/<branch>` currently is (availability risk, forcing a restart/migration at a bad time), and read update logs. Cannot run arbitrary commands. Good design point. It can also read the unauthenticated `/status`. |
| Platform admin (web user) | Hits "Update now" through the API | Same as above. |
| Whoever controls `origin` (upstream repo, a hijacked fork, a MITM on git/HTTPS, a malicious maintainer commit) | Code that the updater then builds and runs | Full host root (see below). This is the realistic high-impact path. |
| RCE inside the updater itself | Has the socket | Host root. |

### 3.3 What a malicious upstream commit can do (INF-002, High)
After `git merge --ff-only` (line 572), the updater runs `docker compose build` and `up --build` on the checked-out tree. The tree controls: `docker-compose.yml` (can add `privileged: true`, `pid: host`, bind `/:/host` for any service, new services), every Dockerfile (`RUN` executes during build with the build daemon's privileges, network access), and `updater/Dockerfile` itself (the updater image is rebuilt from the new tree and then launched with the socket mounted by the bootstrap container, lines 451-459, i.e. the new updater image is trusted blindly). There is no signature verification (`git verify-commit`, `merge --verify-signatures`), no pinned commit allowlist, no diff review, no `compose config` policy check (e.g. forbid privileged, host mounts, unexpected services). The default branch is trusted entirely, including force pushes (ff-only only prevents local divergence, not a hostile upstream history; if the remote force-pushes unrelated history the merge just fails, but a normal malicious commit on top is accepted).
`git fetch origin` uses whatever `origin` URL is in `/repo/.git/config`. Default clones use `https://github.com/wheresfrank/openfamily.git` (docs: `site/quick-start/index.html:71`, `site/script.js:126`), so every default install auto-trusts that GitHub account. TLS trust is the alpine store minus the eMudhra CAs (INF-021). Git hooks: `.git/hooks` are not fetched, so hooks are not a vector; `.gitmodules`/submodules are not updated by this flow (checked, no `submodule` calls).
Impact: single malicious or account-takeover commit on the upstream default branch becomes root on every self-updating server, one click (or API call) later; and `GIT_COMMIT` build arg plus the shared build means it also changes the API binary that handles all location data.
Fix: see 3.5 (no automatic source pull). Interim: set `UPDATER_TOKEN` empty, remove the updater, or add `git verify-commit HEAD` against a pinned maintainer key set before building, plus a compose policy check.
Effort: L. Acceptance: no code path in the product fetches and executes unsigned code from the network; a test commit signed by an unknown key is rejected.

### INF-003 Updater has excessive filesystem reach (High)
Evidence: `docker-compose.yml:167` mounts the entire repo checkout read-write at `/repo` as root; the repo root holds `.env` (JWT secret, DB password, Twilio token, APNs path, `APK_GITHUB_TOKEN`), `apk/`, and `.git`. Plus `/data` volumes. The updater does not need to read `.env` itself (compose reads it, but only because it is run in-container).
Fix: removed by the replacement design; interim, mount only needed paths read-only, and `env_file` reading must be done by the host.
Effort: S (interim) / L (design). Acceptance: compromise of the updater yields no `.env` read (moot once the socket is gone).

### 3.4 Command injection review (checked, no injection found)
All `exec.Command` calls use argv form, never `sh -c` with interpolation, except one fixed shell string: `main.go:458` `"docker compose --project-directory /repo up -d "+updaterService` where `updaterService` is the constant `"updater"` (line 49), so it is not attacker influenced. Other values placed in argv:
- `branch` (from `UPDATE_BRANCH` env or `origin/HEAD`, lines 582-594) is passed as positional args to `git checkout`/`git merge origin/<branch>`/`--track origin/<branch>`. A branch beginning with `-` could be read as an option (`git checkout -b...`-style argument injection). The source is the operator's env or the remote's HEAD symref name; git refuses refnames starting with `-` for branches, so practical risk is Low (INF-015). Add `--` and `git check-ref-format --branch`.
- `hostRepo` (from `docker inspect` mounts, line 511) is concatenated into `-v hostRepo+":/repo"` (454, 456): a host path containing `:` or `,` could alter the mount spec. Self-inflicted only (host path of the operator's own clone). Low.
- `services` from `docker compose config --services` of the freshly merged compose file (360-374): names come from the (untrusted-if-upstream-compromised) compose file but are passed as argv; no shell. Not an injection, but see 3.3.
- `docker rm -f openfamily-updater-selfinstall` and `docker inspect <hostname>`: hostname is the container ID set by Docker; if the compose file ever sets `hostname:` for the updater, `selfImage`/`hostRepoDir` break (robustness, not security).
- No user-controlled HTTP input reaches any command: `/apply` has no body (no `r.Body` read), `/log` has no params. Good.
Other observations: `runWithTimeout` (634-642) kills only the direct process, not children (30 minute timeout); log file created with default perms and may contain build output with secrets echoed from compose (`os.Create`, line 252); `commandTimeout` is applied per command, not per job; state `.tmp` rename is not fsynced (acceptable).

### INF-011 Update source mismatch (Medium)
Evidence: `backend/cmd/server/main.go:95-97` uses `APK_GITHUB_REPO` (default `wheresfrank/openfamily`, `docker-compose.yml:77`) as the repo whose default-branch commit defines "latest". The updater instead pulls from the clone's `origin` and `UPDATE_BRANCH` (main.go:582-594), and the API checker follows the GitHub default branch, not `UPDATE_BRANCH`. A fork that sets `origin` to its own repo but leaves `APK_GITHUB_REPO` shows "update available" forever (or never), and may display a misleading commit from a different project.
Fix: a single `UPDATE_REPO`/`UPDATE_BRANCH` source of truth or (preferred) release-tag based version check (3.5).
Effort: S. Acceptance: the admin panel version check and the deploy tool read the same source.

### INF-015 Token auth hygiene (Low)
Evidence: `main.go:239` `r.Header.Get("X-Updater-Token") == u.token` (not `subtle.ConstantTimeCompare`); no rate limit or lockout; no minimum token length enforced (a 1-character `UPDATER_TOKEN` is accepted; compose only advises `openssl rand -hex 32`); token travels over plain HTTP on the internal network (acceptable, but any container on the network sees it if sniffing is possible, e.g. a compromised caddy/ntfy container sharing the bridge needs `CAP_NET_RAW`, which is a default Docker capability, hence INF-006); `/status` unauthenticated by design (test `TestStatusIsReadableWithoutApplyToken`). API-side, token goes in a header per request (admin_update.go:133).
Fix: `subtle.ConstantTimeCompare`, enforce length >= 32, put the updater on its own network shared only with api, drop `NET_RAW` from all containers.
Effort: S.

### 3.5 Proposed replacement design (no socket, signed releases, operator-run upgrade)
Goal: the product never executes code it fetched itself. The admin UI becomes informational ("version X available, run `./scripts/upgrade.sh`").

1. Release pipeline (CI, on `v*` tag only): build `api` image multi-arch from a pinned base; push to GHCR as `ghcr.io/<owner>/openfamily-api:vX.Y.Z` and by digest; sign with cosign keyless (GitHub OIDC) and attach SBOM (syft) and SLSA provenance (`actions/attest-build-provenance`); publish `release.json` (version, image digest, min compatible previous version, migration range, checksum of the APK) and a signed `SHA256SUMS`. Protect the tag with a GitHub ruleset and require 2-person review for release branches.
2. Compose uses image references with `${OPENFAMILY_VERSION}` and digests (`image: ghcr.io/<owner>/openfamily-api@${OPENFAMILY_API_DIGEST}`), no `build:` for api. Remove the `updater` service, the socket mount, and `REPO_DIR` host-path gymnastics entirely.
3. API keeps a read-only version check: GET `release.json` from the configured release URL, verify its signature with an embedded public key (minisign/cosign key or Sigstore bundle) before showing "update available". It never applies anything. `UPDATER_*` config removed.
4. `scripts/upgrade.sh <version>` run by the operator on the host:
   - preflight: disk space, compose file diff against the running one, `.env` has all newly required vars;
   - `cosign verify` the images against the expected identity (workflow path + tag) and refuse otherwise;
   - backup: `pg_dump -Fc` plus `pg_dumpall --globals-only`, copy `caddy_data`, `ntfy_etc`, `.env`, `apk/` to `backups/<ts>/`, record current image digests and current migration version (`schema_migrations`) in `backups/<ts>/MANIFEST`;
   - `docker compose pull`, `docker compose up -d`, wait for api healthy and `/healthz` plus a smoke call;
   - on failure: automatic rollback = restore previous digests into `.env`, `docker compose up -d`; if migrations advanced (`schema_migrations.version` > recorded), restore the DB from the dump (document that the schema may not roll back by down migrations alone: see INF-013);
   - append to `upgrade.log`; keep last N backups.
5. `scripts/rollback.sh <backup-id>` restores digests and DB from a chosen backup; `scripts/restore-test.sh` restores the latest dump into a throwaway Postgres container and runs row-count checks, intended for a weekly cron/CI job.
6. Optional convenience for less technical operators: Watchtower-style notification only (no auto-apply), or a host systemd timer that runs `upgrade.sh --check` and emails/pushes via ntfy.
Effort: L. Acceptance: `docker compose config` contains no `docker.sock`; a deliberately tampered image fails `upgrade.sh`; rollback drill restores a pre-upgrade state with matching row counts; documented in `docs/self-hosting.md`.

---

## 4. GitHub workflows (scope 3)

Checked: no workflow uses `pull_request_target` or `workflow_run` (none of the five), so the classic "untrusted PR code with secrets" risk does not exist today. Secrets are used only in `apk.yml`, which triggers on `push` to `main` and `workflow_dispatch`, not on PRs; fork PRs get no secrets. No `${{ github.event.* }}` interpolation of attacker-controlled text into `run:` (only `github.run_number` and `github.sha`, both safe).

### INF-012 Permissions and pinning (Medium)
- Pinned by mutable tag, not commit SHA: `actions/checkout@v4` (apk.yml:35; ca-trust.yml:12; pages.yml:28; test.yml:18,31,44,68; web-preview.yml:22), `actions/setup-java@v4` (apk:38), `subosito/flutter-action@v2` (apk:44; test:45,69; web-preview:23), `actions/upload-artifact@v4`, `softprops/action-gh-release@v2` (apk:94, third-party, receives `contents: write`), `actions/setup-node@v4`, `actions/setup-go@v5`, pages actions. A compromised third-party tag (softprops, subosito) in `apk.yml` runs with the signing keystore decoded on disk and a write token.
- `test.yml` and `web-preview.yml` declare no `permissions:`; they get the repository default token scope (may be read/write depending on repo settings, needs verification). Add `permissions: contents: read`.
- `apk.yml:27-28` grants `contents: write` for the whole workflow including the Flutter build steps; scope it to the publish job only (split build and release jobs).
- `apk.yml` has no `concurrency:` group; two quick merges race on `overwrite_files`. `ca-trust.yml`/`test.yml` have none either (low value).
- `pages.yml:11-14` permissions are appropriately minimal.
Fix: pin all `uses:` by SHA with a trailing `# vX.Y.Z` comment; Dependabot `github-actions` ecosystem; default-deny permissions at top of each file.
Effort: S. Acceptance: `grep -rn 'uses:' .github | grep -v '@[0-9a-f]\{40\}'` is empty; every workflow has a top-level `permissions`.

### Signing key handling (apk.yml:50-67) (checked, mostly fine, hardening noted)
Decodes `ANDROID_KEYSTORE_BASE64` into `app/android/upload-keystore.jks` and writes `key.properties`. Fails fast if secrets are missing (good). Keystore and properties are never cleaned up (ephemeral runner, but they sit in the workspace and subsequent third-party actions such as `upload-artifact` could pick them up if a path were widened; today paths are specific). The same password is used for store and key (line 63-64). A release is a tester APK `apk-N` signed with the **upload** key: this key is also what the README says to back up (`README.md:388`); if it is the Play upload key rather than an app-signing key behind Play App Signing, the APK distributed outside Play is signed with a key whose loss/compromise matters. Recommendation: use a separate key for sideloaded releases from Play upload key (needs verification of current practice); store secrets in a GitHub `environment` with required reviewers so that only tagged releases can use them; `rm -f` the key files in an `if: always()` step. No attestation or checksum is published alongside the APK (INF-005).

### INF-005 APK integrity chain (High)
Evidence: `backend/internal/apkrelease/github.go` downloads the latest `v*` release asset from `APK_GITHUB_REPO` (default `wheresfrank/openfamily`, compose:77) and caches it in `APK_DIR`, which the admin panel then serves to family members for install. Grep for `sha256|checksum|digest|signature|apksigner` in that package returns nothing outside the response size cap (`github.go:246`), so no hash, signing-certificate, or attestation is verified. CI also publishes no checksum file.
Failure scenario: anyone who can publish a release or tamper with the asset on that repo (or the operator's token holder, or a TLS MITM given a rogue CA) causes every family phone installing from the server to receive a trojaned app with location access. Android will refuse an update signed with a different key than the installed app, but first installs are not protected.
Fix: publish `SHA256SUMS` plus cosign/GitHub attestation in CI; server verifies the asset hash and, on Android-side, pin the signing certificate SHA-256 in config (`APK_SIGNING_CERT_SHA256`), verifying with `apksigner`-equivalent parsing or at minimum the release body hash; show the fingerprint in the admin UI. When forked, the new owner's key is the pinned one.
Effort: M. Acceptance: a tampered asset with a valid release is rejected and logged; unit test with mismatched hash.

### Release automation and upstream-specific targets
- Tag format: CI publishes `apk-<run_number>` prereleases (`make_latest: false`); user-facing releases `v*` are created manually (not by any workflow in this tree; needs verification of how `v0.1.0` is created). There is no workflow that builds or publishes Docker images, tags backend releases, generates SBOMs or provenance, runs `govulncheck`, `go vet`, `staticcheck`, `gosec`, Trivy, or CodeQL. `test.yml` runs only `go test`, `flutter analyze/test`, and an iOS simulator build.
- `test.yml` integration: `backend` tests run without a database service, so the DB layer (`internal/db`, no test files per `docs/architecture/CURRENT_STATE.md`) and migrations are not exercised in CI. Add a job with a `timescale/timescaledb-ha:pg16` service that runs `migrate up` then `down` then `up` for all 24 migrations.
- `pages.yml:39` guard `github.repository == 'wheresfrank/openfamily'` and `:41` inject a third-party analytics script `stats.subwiz.ai` with site id `pa-L7jWcNReMehlGYzagVUpb` and domain `openfamily.app`; also CSP in `site/**/*.html` allowlists `stats.subwiz.ai` (e.g. `site/index.html:6`). This belongs to the upstream owner; a fork must change or remove it. It is correctly gated so forks get no analytics (checked, good).
- `ca-trust.yml`: read-only perms, `pull_request`, builds both images with `--pull`, runs trust-store checks (checked OK). Runs on every PR including docs-only ones; add `paths:` if cost matters.
- `web-preview.yml:29`: runs `flutter create` at build time on PRs: acceptable (no secrets); artifact retention 7 days (good).

---

## 5. CA trust incident (scope 4)

What it is (`docs/ca-trust-incident.md`, `updater/distrust-compromised-cas.sh`, `scripts/ca-trust.test.mjs`, `scripts/check-ca-trust.sh`, `scripts/ca-fixtures/{aaa,emsign,isrg}.pem`, `.github/workflows/ca-trust.yml`): in October 2026 (Mozilla bug 2083449) the eMudhra emSign G3 hierarchies were treated as compromised. The repo disables four trust anchors by SHA-256 fingerprint (emSign ECC Root CA G3, emSign Root TLS CA G3 self-signed and cross-signed, and AAA Certificate Services as an alternate path) in every image stage (api build + runtime, updater build + runtime: `backend/Dockerfile:4-5,38-40`, `updater/Dockerfile:4-5,15-17`), by moving the `.crt` out of the import glob, marking it `!` in `ca-certificates.conf`, and running `update-ca-certificates --fresh`. CI validates with public fixtures and an `openssl verify` against the built images. The Go version bump to 1.27.3 in the latest commit (6b6968c) is part of the same response.

Is it still relevant (today is 2026-10-25, roughly the same month)? Yes for now. The control is fail-safe (corrupt cert fails the build), idempotent, and tested (script lines 14-43 reviewed: fingerprint computed with openssl per cert, error not masked, tolerant of missing config). Limits to note:
- It only covers the api and updater images. Caddy (its ACME client and any outbound trust), ntfy (outbound to FCM/APNs relays if configured), the Postgres image, the host, and phones are out of scope (the doc says so).
- It depends on `alpine:3.22` shipping a bundle that still contains those roots; once alpine and Mozilla's bundle drop them, the script becomes a no-op. Needs verification of the alpine package version at which Mozilla removed them; schedule a removal review (INF-021).
- Copying the script into the backend build context duplicates a file between `updater/` and `backend/` through the `!updater/distrust-compromised-cas.sh` dockerignore entry; fine, but couples the two build contexts.
- Not a substitute for a compromise assessment: the doc rightly says it "does not establish whether any running deployment was attacked".
Fix/housekeeping (Info, S): add a calendar-dated TODO to remove the step once base images no longer ship these roots; keep the fixture test as a regression guard. Acceptance: when removed, `ca-trust.yml` still verifies the roots are absent from the final bundle.

---

## 6. Backups and restore (scope 5)

What exists: prose only. `docs/self-hosting.md:61-69` and `README.md:483` ("snapshot the volume, schedule pg_dump"), `README.md:388` keystore backup advice. No script, cron/compose service, retention policy, encryption, off-host copy, or restore procedure; no restore test; no mention of `caddy_data` (ACME account and issued certificates; loss means re-issuance and possible Let's Encrypt rate limits), `ntfy_etc`/`ntfy_cache` (subscriptions and cache), `apk/` (re-fetchable), `deploy_meta`, `.env` (JWT secret: losing it logs everyone out; losing `POSTGRES_PASSWORD` locks you out of an initialised volume), `pg_dumpall --globals-only`.

### INF-004 No backup/restore tooling and no pre-update snapshot (High)
Failure scenarios: (a) disk failure or `docker compose down -v` destroys the only copy of family location history and accounts; (b) the update flow (updater `run`, main.go:245-348) records `PreviousRef` but never snapshots the DB and never rolls back; the API applies migrations on start (`backend/cmd/server/main.go:46`), so a bad release plus migrations can leave the data at a newer schema than the older code can read, with no documented way back; (c) a naive `cp` of the `pgdata` volume while running gives an inconsistent copy; (d) TimescaleDB restore needs `timescaledb_pre_restore()`/`post_restore()` around `pg_restore`, which generic "schedule pg_dump" advice does not mention.
Fix: add `scripts/backup.sh` (`pg_dump -Fc` via `docker compose exec -T postgres`, globals, `.env`, caddy_data; gzip + age/gpg encryption; retention N daily/W weekly; optional rclone/S3 target), `scripts/restore.sh` (stop api, create db, `timescaledb_pre_restore`, `pg_restore`, `timescaledb_post_restore`, start api, verify `schema_migrations`), `scripts/restore-test.sh`, a compose `backup` profile service with a cron wrapper, and documentation with RPO/RTO.
Effort: M. Acceptance: `scripts/backup.sh && scripts/restore-test.sh` passes in CI against seeded data; documented drill restores a fresh host to row-count parity; backup directory excluded from git and mode 0700.

---

## 7. Database (scope 6)

Inventory: 24 migrations (`backend/internal/db/migrations/000001..000024`), every migration has a `.down.sql` (checked: 24 pairs present). Embedded with `go:embed` (`db.go:16`) and applied at API start by golang-migrate (`db.go:42-55`, called at `main.go:46`) before the pool opens.

### Reversibility (checked)
- Down files are present and sensible for structural changes: 000001 (drops tables, leaves the `postgis`/`timescaledb` extensions in place, correct), 000002, 000003 (back-fills NULL before `SET NOT NULL`), 000005, 000007 (restores columns with defaults), 000010 (`remove_retention_policy`), 000012, 000015, 000017 (maps `gym` to `custom` before restoring the CHECK), 000024.
- Down migrations are lossy by nature where columns/tables hold data (000005, 000007, 000015 avatar bytes, 000024, 000019/000020 if they drop tables). Treat as development-only; production rollback must be restore-from-backup (INF-004/013).
- 000023 (`reconcile_invite_codes`) exists because two histories both used version 000014 (comment in the file). Down is a no-op or minimal (needs verification of its down content); this is a legacy-compat migration; a fresh install is unaffected. Note for the fork: do not renumber.
- `golang-migrate` runs each file as a single multi-statement call without wrapping explicit transactions (postgres driver executes the whole file in one `Exec`; files with several statements run in an implicit transaction, but `create_hypertable`/DDL combos and `CREATE INDEX CONCURRENTLY` cannot). A failure leaves `schema_migrations.dirty = true`, after which `m.Up()` returns an error on every start (db.go:51) and the API crash-loops until an operator runs `migrate force`, with no documented procedure.

### INF-013 Locking and failure risk (Medium)
Evidence and risks:
- `000012_member_positions.up.sql` backfill: `SELECT DISTINCT ON (d.user_id) ... FROM locations l JOIN devices d ... ORDER BY d.user_id, l.ts DESC` scans and sorts the whole hypertable (up to 90 days of points) at API boot. Holds a transaction and read locks, delays startup; on a large deployment this exceeds the compose healthcheck budget (api healthcheck `interval 10s, retries 6`, compose lines 102-107, i.e. about 60 seconds of start grace without `start_period`) and Docker may mark it unhealthy mid-migration. Fix: use a `LATERAL` per-device `ORDER BY ts DESC LIMIT 1` using `idx_locations_device_ts`; add `start_period: 120s`.
- `000015` (`ADD COLUMN ... BYTEA` and several CHECK constraints added with `ALTER TABLE users`) takes `ACCESS EXCLUSIVE`; the `users` table is small, so duration is negligible. Checked fine.
- `000019` unique partial index on `users.phone`: build is quick on a small table (fine). `000013`/`000020` also fine.
- `000024` `ADD COLUMN ingest_key_hash TEXT` (nullable, no default): metadata only (fine).
- Concurrent starts: golang-migrate takes a Postgres advisory lock, so two API instances will serialise (checked by library behavior, needs verification against v4.19.1).
- Migration runs with the application role (the same superuser `POSTGRES_USER`); `CREATE EXTENSION` in 000001 requires it. The app at runtime also uses that superuser (single DSN), so a SQL injection or API compromise is full DB compromise including `COPY ... PROGRAM`. Fix: create a least-privilege runtime role (no SUPERUSER, DML only) and keep the migration role separate. Severity Medium, grouped here. Effort M.
Acceptance: migration of a seeded 5M-row `locations` table completes under 60 seconds in CI; runtime role cannot `CREATE EXTENSION` or `COPY PROGRAM`; a runbook for dirty-state recovery exists.

### INF-014 Timescale / PostGIS design (Medium)
Evidence: `000001_init.up.sql` creates `locations` as a hypertable on `ts` (`create_hypertable('locations','ts', if_not_exists => TRUE)`) with defaults: 7-day chunks, no `chunk_time_interval` tuning, no space partitioning. Indexes: `idx_locations_device_ts (device_id, ts DESC)` (needed by history queries), `idx_locations_geom GIST (geom)` (no query in `internal/` filters `locations.geom` spatially: grep shows `ST_DWithin` only against `places.geom`; `locations.geom` is only read via `ST_X/ST_Y`), plus the default `locations_ts_idx` created automatically by Timescale (duplicative of the composite index for most queries). The GiST index on points costs insert throughput and disk for no read benefit (needs verification against all handler SQL, but a grep of `ST_`/`geom` in `backend/internal` found no spatial predicate on `locations`).
- Retention: `000010` `add_retention_policy('locations', INTERVAL '90 days')`; fixed in SQL, and noted in `docs/architecture/CURRENT_STATE.md` as hard-coded. Other tables are never pruned: `audit_log` (000011, grows unbounded, indexed on `created_at`), `geofence_events`, `geofence_event_devices`, `alerts` (with `lat/lon` of SOS events, indefinite), `member_positions` (one row per user, fine). The privacy claims in `PRIVACY.md` should be reconciled with these indefinite stores (needs verification of what PRIVACY.md promises).
- Compression: none configured. Location points compress very well (typically 90 percent plus), but note that an orderby/segmentby of `device_id, ts DESC` and `compress_after => 7 days` is the natural policy; compression interacts with the FK `locations.device_id -> devices(id)` and with UPDATE/DELETE on compressed chunks (device deletion cascade on compressed chunks may be slow or restricted depending on Timescale version, needs verification).
- Storing coordinates as a `GEOMETRY(Point,4326)` while `member_positions`, `alerts`, and `geofence_*` pending columns use separate `lat/lon double precision`: inconsistent, fine functionally.
- PostGIS usage is limited to `ST_SetSRID/ST_MakePoint/ST_X/ST_Y` and `ST_DWithin(geom::geography, ...)` (place.go:112, geofence_eval.go:114,195). `ST_DWithin` with a `::geography` cast on `places.geom` defeats the GiST index `idx_places_geom` (it is on the geometry column, the cast makes the planner unable to use it); places per family are few so it does not matter at family scale, but it shows the index is unused. Either index `(geom::geography)` or drop the index.
- The `ha` image bundles PostGIS and Timescale (checked: matches `CREATE EXTENSION postgis; timescaledb`). A PG major upgrade (pg16 to pg17) has no documented path; floating tag `pg16` can change minor Timescale versions on pull, and Timescale extension updates (`ALTER EXTENSION timescaledb UPDATE`) are not automated (needs verification of how the image handles it).
Fix: drop `idx_locations_geom` (after verification), add `add_compression_policy('locations', INTERVAL '7 days')` with `segmentby device_id`, make retention configurable via a settings table or env (`LOCATION_RETENTION_DAYS`) applied at startup with `alter_job`, add retention for `audit_log`/`alerts`/`geofence_events`, document upgrade procedure.
Effort: M. Acceptance: `EXPLAIN` shows no seq scans on history/latest queries; chunk compression visible in `timescaledb_information.chunks`; disk usage on a synthetic 1M-point set drops at least 70 percent after compression.

### INF-017 Connection pooling and server timeouts (Low)
Evidence: `db.go:25` `cfg.MaxConns = 10` hard-coded; no `MinConns`, `MaxConnLifetime`, `MaxConnIdleTime`, `HealthCheckPeriod`, or `statement_timeout`/`lock_timeout`; `pgxpool` defaults otherwise. Ping timeout 5 seconds with no retry (`db.go:32-37`): if Postgres is slower than the api (compose `depends_on: service_healthy` mitigates, but not for restarts), the API exits and relies on `restart: unless-stopped`. Migration uses a separate lib/pq connection (golang-migrate postgres driver, `lib/pq` in go.mod) so effective connections are pool plus one. Postgres default `max_connections=100` is fine for a single API.
`backend/cmd/server/main.go:281-285` sets only `ReadHeaderTimeout: 10s`; no `ReadTimeout`, `WriteTimeout`, `IdleTimeout`, or `MaxHeaderBytes` (WebSocket endpoints complicate global write timeouts; use per-handler deadlines or `http.NewResponseController`). Slowloris-style body trickle on the location ingest endpoints is possible if Caddy does not cap it (it does not, see INF-010).
Fix: env `DB_MAX_CONNS` (default 10), set `MaxConnLifetime=30m`, `MaxConnIdleTime=5m`, `HealthCheckPeriod=1m`, connection retry with backoff on start, add `IdleTimeout: 120s` and `ReadTimeout` for non-WS routes.
Effort: S. Acceptance: config tests for the new env vars; start succeeds when Postgres comes up 20 seconds late.

---

## 8. Config handling and env inventory (scope 7)

Code: `backend/internal/config/config.go`; template `.env.example`; compose pass-through at `docker-compose.yml:33-87`.

### Defaults and validation (checked)
- `Validate()` (config.go:219-242): requires `JWT_SECRET` non-empty, not the placeholder, and at least 32 characters (it checks `len` of the string, i.e. 32 bytes of text, not entropy); in production requires an explicit `DATABASE_URL` without `sslmode=disable` (substring check, INF-008); requires TLS config or `TLS_BEHIND_PROXY=true` or explicit `INSECURE_HTTP=true` in all environments. Good fail-fast design, with unit tests in `config_test.go`.
- Gaps: `APP_ENV` is not validated against an allowlist (a typo such as `prod` or `Production` silently runs as development and skips the DB checks); `getenvBool`/`getenvDuration` silently fall back to the default on a parse error (e.g. `TLS_BEHIND_PROXY=ture` becomes false and `ACCESS_TOKEN_TTL=15` becomes 15m default, no warning); the code default of `REFRESH_TOKEN_TTL` is 30d (config.go:182) while compose sets `720h` (equal, consistent); `ALLOWED_ORIGIN=*` is not rejected (needs verification of how it is used in `ws.go`/CORS); no validation of `UPDATER_TOKEN` length (INF-015); `PLATFORM_ADMIN_PASSWORD` complexity is not validated in config (handled elsewhere, needs verification); `PUBLIC_BASE_URL` non-https silently degrades to putting lat/lon in SMS (documented in `.env.example:93-97`).
- Secrets in env: `JWT_SECRET`, `TWILIO_AUTH_TOKEN`, `APK_GITHUB_TOKEN`, `PLATFORM_ADMIN_PASSWORD`, `UPDATER_TOKEN`, DB URL with password are plain env vars (visible in `docker inspect` and `/proc/<pid>/environ` to anyone with docker access); `PLATFORM_ADMIN_PASSWORD` stays in the environment after first use. Prefer Docker secrets / `*_FILE` variants and unset the admin password after bootstrap (Low). The Twilio auth token is additionally stored in DB table `sms_settings` (migration 000022) in plaintext (`auth_token TEXT`): needs verification of whether the handler encrypts it; the migration does not.

### Env var inventory

| Variable | Default (code / compose) | Required for minimal install? | Notes |
|---|---|---|---|
| `JWT_SECRET` | none / `change-me-in-production` (rejected) | **Yes** (32+ chars) | `.env.example:30` |
| `POSTGRES_PASSWORD` | `openfamily` / `change-me` in example | **Yes in practice** (change it) | compose:113 |
| `POSTGRES_USER`, `POSTGRES_DB` | `openfamily` | No | compose:111-112 |
| `DATABASE_URL` | local default / built from POSTGRES_* | No in dev; **Yes in production** | config.go:225 |
| `SITE_ADDRESS` | `:80` | **Yes for HTTPS** (domain) | compose:17; read by Caddy and API |
| `APP_ENV` | `development` | Recommended `production` | not allowlisted |
| `TLS_BEHIND_PROXY` | `false` in code / `true` in compose | No (compose sets) | config.go:187 |
| `INSECURE_HTTP` | `false` | No | opt-out |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | empty | No | direct TLS |
| `HTTP_ADDR` | `:8080` | No | compose sets; healthcheck depends on it |
| `ACCESS_TOKEN_TTL`, `REFRESH_TOKEN_TTL` | `15m`, `30d`(code)/`720h` | No | hard-set in compose (lines 43-44), not overridable via .env |
| `ALLOWED_ORIGIN` | empty | No | CORS/WS origin |
| `PLATFORM_ADMIN_EMAIL`, `PLATFORM_ADMIN_PASSWORD` | empty | **Yes to use the admin panel**; setting the email also closes registration | .env.example:76-83 |
| `NTFY_BASE_URL` | empty (code) / `http://localhost:2586` | Only for push | must be https in production |
| `PUSH_ADDRESS`, `CADDYFILE` | empty / `Caddyfile` | Only for public ntfy | `CADDYFILE` is not in `.env.example` (undocumented there) |
| `VERBOSE_PUSH` | `false` | No | privacy |
| `TILE_URL`, `SATELLITE_TILE_URL` | OSM / Esri | No | OSM tile policy applies to heavy use (Info) |
| `APNS_KEY_FILE/KEY_ID/TEAM_ID/TOPIC/PRODUCTION` | empty / false | Only for iOS push | key must be mounted |
| `TWILIO_ACCOUNT_SID/AUTH_TOKEN/FROM`, `PUBLIC_BASE_URL` | empty | Only for SMS | also in admin Settings |
| `APK_DIR` | empty (code) / `/data/apk` | No | |
| `APK_GITHUB_REPO` | empty (code) / **`wheresfrank/openfamily`** | No, but must change when forked | INF-018 |
| `APK_GITHUB_TOKEN` | empty | Only for private forks | |
| `FLUTTER_APP_DIR` | `./app` | No | on-server build only; **not** passed through in compose |
| `UPDATER_URL` | empty / `http://updater:8081` | No | INF-001/002 |
| `UPDATER_TOKEN` | empty | No (empty disables apply) | |
| `UPDATE_BRANCH` | empty | No | updater only |
| `DEPLOY_REF_FILE` | empty / `/data/deploy/deployed-ref` | No | |
| `REPO_DIR` | `.` | No (compose-internal) | host-path workaround |
| `GIT_COMMIT` | empty | No (build arg) | |
| `LISTEN_ADDR`, `REPO_DIR`, `DATA_DIR` | updater-only | No | updater/main.go:84-87 |

Minimal install (compose, HTTP on LAN): `JWT_SECRET`, `POSTGRES_PASSWORD`; add `SITE_ADDRESS`, `APP_ENV=production`, `DATABASE_URL` with TLS, and `PLATFORM_ADMIN_EMAIL`/`PASSWORD` for a public one. Undocumented/misaligned: `CADDYFILE`, `LISTEN_ADDR`, `DATA_DIR`, and `.env.example` lines 21/25 versus placeholders that are accepted (INF-009).

---

## 9. Upstream references to `wheresfrank` (scope 8)

Command: `grep -rniI wheresfrank . --exclude-dir=.git --exclude-dir=node_modules --exclude=go.sum`. Go import lines (about 65 files under `backend/`) all use the module path and change with a single module rename.

| Location | Reference | Should become |
|---|---|---|
| `backend/go.mod:1` | `module github.com/wheresfrank/openfamily/backend` | New module path (e.g. `github.com/<new-owner>/<repo>/backend`); then `gofmt`/sed all imports |
| `updater/go.mod:1` | `module github.com/wheresfrank/openfamily/updater` | New path, or delete with the updater (INF-002) |
| `backend/Dockerfile:32` | ldflags `-X github.com/wheresfrank/openfamily/backend/internal/config.buildVersion` | Must match the new module path or the version silently stays `dev` (verify after rename) |
| `backend/internal/config/config.go:169` | comment with module path | Update with module |
| `backend/**/*.go` imports (cmd/server/main.go:18-26, admin*.go, handlers/*.go, middleware/*.go, serverupdate, apkrelease, etc.) | `github.com/wheresfrank/openfamily/backend/internal/...` | New module path (mechanical) |
| `backend/internal/apkrelease/github_test.go:455-456` | test fixture `wheresfrank/openfamily` | Any neutral fixture (`octo/repo`) |
| `docker-compose.yml:77` | `APK_GITHUB_REPO:-wheresfrank/openfamily` default | New owner/repo, or no default (empty = disabled) |
| `.env.example:119-120` | comment + `APK_GITHUB_REPO=wheresfrank/openfamily` | New owner/repo |
| `.github/workflows/pages.yml:39` | `if: github.repository == 'wheresfrank/openfamily'` | New repo, plus replace analytics (`stats.subwiz.ai`, `pa-L7jW...`, domain `openfamily.app`, lines 41-49) or remove |
| `SECURITY.md:7` | security advisory URL | New repo's advisory URL (also the contact process) |
| `app/README.md:3` | link to repo | New repo |
| `ROADMAP.md:7` | M0 task text | Remove when done |
| `docs/architecture/CURRENT_STATE.md:26-27` | notes | Update |
| `web/src/pages/DomainSettingsCard.tsx:14` | `https://github.com/wheresfrank/whereabouts/blob/main/docs/custom-domain.md` (different repo name, likely stale/broken, INF-019) | New repo's `docs/custom-domain.md` URL; also rebuild `backend/web/dist` (committed artifact) |
| `site/script.js:126` | `git clone https://github.com/wheresfrank/openfamily.git openfamily` | New clone URL |
| `site/index.html:30,125,324,375,388` | JSON-LD `codeRepository`, nav link, clone command, CTAs | New repo URL |
| `site/quick-start/index.html:49,68,71,122,135` | links and clone command | New repo URL |
| `site/docs/index.html:49,60,76,108,118,121,134` | links | New repo URL |
| `site/compare/index.html:49,61,64,167,183` | links (line 61 also mentions `NexaFlowFrance/OpenFamily` as a different product: keep) | New repo URL |
| `site/privacy/index.html:49,60,107,119`; `site/privacy.html:54`; `site/delete-account.html:43`; `site/llms.txt:6` | links to repo and PRIVACY.md | New repo URL |
| Related non-`wheresfrank` upstream identifiers worth renaming together: `openfamily.app` (site meta, `site/sitemap.xml`, `site/robots.txt`, `PRIVACY.md`, `app/lib/screens/privacy_policy_screen.dart`, `assets/google-play/*.py`), `stats.subwiz.ai`, Android applicationId/iOS bundle id `app.openfamily` (`test.yml:90`), Play assets | New domain, bundle id, analytics | Decide with branding; changing the Android application id breaks updates for existing installs (note for M0) |

Total: roughly 36 distinct non-Go-import hits plus about 65 Go import lines. `backend/web/dist/assets/index-*.js` contains a bundled OSM URL only, no `wheresfrank` string found beyond the source file above (the dist bundle is a committed build artifact; rebuild after changing the TSX).

---

## 10. License and third-party inventory (scope 9)

Project license: GNU AGPL-3.0 (`LICENSE`, header "GNU AFFERO GENERAL PUBLIC LICENSE Version 3"). AGPL section 13 obliges anyone who modifies and hosts the server to offer the corresponding source to network users; relevant to forks and to the embedded web admin. No SPDX headers and no `NOTICE`/third-party file exist (INF-020). Licenses below are from general knowledge of the upstream projects and need verification with `go-licenses` / `flutter pub deps` / `license_checker` before release.

### Go (`backend/go.mod`, Go 1.27.3)
| Module | Version | License (needs verification) |
|---|---|---|
| github.com/coder/websocket | v1.8.15 | ISC |
| github.com/go-chi/chi/v5 | v5.3.1 | MIT |
| github.com/golang-jwt/jwt/v5 | v5.3.1 | MIT |
| github.com/golang-migrate/migrate/v4 | v4.19.1 | MIT |
| github.com/jackc/pgx/v5 | v5.10.0 | MIT |
| github.com/pquerna/otp | v1.5.0 | Apache-2.0 |
| golang.org/x/crypto | v0.55.0 | BSD-3-Clause |
Indirect: boombuler/barcode (MIT), jackc/pgpassfile, pgservicefile, puddle/v2 (MIT), lib/pq v1.10.9 (MIT), golang.org/x/{sync,sys,text} (BSD-3-Clause). `updater/go.mod` has zero dependencies (stdlib only; checked). No `vendor/` directory in `backend/` (checked).

### Web admin (`web/package.json`, embedded into `backend/web/dist`)
react 18.3.x (MIT), react-dom (MIT), leaflet 1.9.x (BSD-2-Clause), react-leaflet 4.x (Hippocratic-2.1: needs verification, this license is not OSI-approved and restricts use for human-rights violations; confirm and consider replacing or using plain Leaflet); dev: vite, @vitejs/plugin-react, typescript (MIT/Apache-2.0). The built bundle `backend/web/dist/assets/index-DowKrZqS.js` is **committed**, so binary provenance depends on whoever built it (INF-020).

### Flutter (`app/pubspec.yaml`, version 0.1.0+1)
Direct dependencies: flutter_secure_storage ^9.2.2, local_auth ^2.3.0, http ^1.2.2, background_locator_2 ^2.0.6 (overridden by vendored copy), shared_preferences ^2.3.0, flutter_map ^7.0.2, latlong2 ^0.9.1, share_plus ^10.0.0, permission_handler ^11.3.1, image_picker ^1.1.2, flutter_native_contact_picker ^0.0.12, geolocator ^13.0.2, battery_plus ^6.0.0, google_api_availability ^5.0.1, android_intent_plus ^5.1.0, web_socket_channel ^3.0.0, connectivity_plus ^6.1.0, flutter_local_notifications ^22.3.0, unifiedpush ^6.2.0; dev: flutter_test, flutter_lints ^4.0.0. Most Flutter-team and community plugins are BSD-3-Clause or MIT; flutter_map is BSD-3-Clause; `unifiedpush` and `flutter_native_contact_picker` licenses need verification (unifiedpush is Apache-2.0 per upstream, unconfirmed here). `google_api_availability` relates to Google Play Services (proprietary service dependency, not a code-license issue, but F-Droid-style distribution should be considered).
Vendored code: `app/packages/background_locator_2` (patched fork; its `LICENSE` file carries MIT-style text with "Copyright 2020 REKAB / Copyright 2022 Yukams"; checked first lines), referenced through `dependency_overrides` (`pubspec.yaml` bottom). Needs a `NOTICE` documenting the patches, and MIT permits relicensing within AGPL as long as the notice is kept. Map data/services: OSM tile servers and Esri World Imagery are used by default (`config.go:18-22`): OSM's tile usage policy discourages heavy use and Esri imagery has its own terms (needs verification for redistribution and production use); provide guidance for self-hosted tiles.
Fix: run `go-licenses report ./...`, `dart pub deps`/`flutter pub run license_checker`, `npm ls --license`/`license-checker`, commit `THIRD_PARTY_NOTICES.md`, add CI check with an allowlist, generate CycloneDX SBOM per release, and build `backend/web/dist` in the Docker build instead of committing it.
Effort: M. Acceptance: CI fails on a disallowed license; SBOM attached to each release.

---

## 11. Checked and fine (INF-022, Info)

- No `pull_request_target`; secrets only on `push`/`workflow_dispatch` (all five workflows).
- Published ports are only caddy 80/443 and ntfy on `127.0.0.1:2586` (`docker-compose.yml:12-14,137-138`); postgres, api, updater are not published.
- API healthcheck syntax and Postgres healthcheck correct; `api` waits for healthy Postgres (`depends_on` condition, lines 98-100).
- `JWT_SECRET` placeholder and short values are rejected in every environment (config.go:221).
- Cleartext HTTP is refused unless proxy/TLS/explicit opt-out is declared (config.go:234-240).
- Updater `/apply` accepts no body and no parameters; all `exec.Command` calls use argv without a shell (apart from one constant string); empty token fails closed (main.go:239); `--ff-only` prevents clobbering local commits; interrupted-job recovery exists; updater has no third-party Go dependencies.
- Build contexts are allowlisted via `Dockerfile.dockerignore`, so `.env` and `apk/` are not copied into images; only `.git/HEAD` and refs are.
- Multi-stage builds with static, stripped binaries; Go toolchain pinned to a patch version; CI builds with `--pull`.
- CA distrust implementation validated by fixtures and by image-level checks (`ca-trust.yml`).
- All 24 migrations have down files; destructive downs normalise data first where a constraint is restored (000003, 000017).
- Avatars are in the DB with size and type CHECKs (000015); the DB-held design keeps them inside backup scope.
- Passwords/ingest keys: ingest key stored as SHA-256 hash only (000024 comment).

## 12. Suggested order of work
1. INF-001/INF-002: make the updater opt-in now, then replace with the signed-release flow (3.5).
2. INF-004 and INF-013: backup/restore scripts before any further schema work or releases.
3. INF-005: APK integrity, then INF-006/007/008/009/010 hardening in one compose PR.
4. INF-012 workflow pinning and permissions; add DB integration test job.
5. INF-018 rename (single mechanical PR after the module path decision), INF-020 licenses.
