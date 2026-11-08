# Current State (baseline audit, 2026-10-25)

Evidence gathered by reading the tree and running the backend test suite. Anything not listed here was not verified.

## Stack
- Backend: Go (`backend/`, go.mod says go 1.27.3), chi router, pgx, golang-migrate, coder/websocket. 24 SQL migrations.
- DB: `timescale/timescaledb-ha:pg16` (TimescaleDB + PostGIS image).
- App: Flutter (`app/`), Android and iOS projects present, vendored `packages/background_locator_2`.
- Web admin embedded in the API binary (`backend/web`).
- Deployment: Docker Compose with caddy, api, postgres, ntfy, updater services.
- CI: `.github/workflows` apk, ca-trust, pages, test, web-preview.
- License: AGPL-3.0 (LICENSE present).

## Verified
- Backend `go test ./...` passes in a golang container: cmd/server, apkrelease, auth, config, handlers, middleware, push, serverupdate, sms all `ok`. db, models, web have no test files.
- 64 Go/Dart test files exist. Flutter tests were NOT run (Flutter not installed on this host).

## Model facts relevant to the rebuild
- One family per user: `users.family_id` is a single nullable column. Multiple circles needs a schema change (M3).
- History retention is fixed at 90 days (`handlers/history.go`, migration 000010). Needs to be configurable (M4).
- Auth: email/password, optional TOTP, access 15m / refresh 720h, `token_version` for revocation, per-IP auth rate limits.
- WebSocket origin check uses `ALLOWED_ORIGIN` patterns (`handlers/ws.go`).
- Push: ntfy/UnifiedPush on Android, APNs for iOS. SMS via Twilio only.

## Upstream references to replace (M0)
- `go.mod` module path `github.com/wheresfrank/openfamily/backend`.
- `APK_GITHUB_REPO` default `wheresfrank/openfamily` in `docker-compose.yml` and `.env.example`.
- `SECURITY.md` advisory URL, `app/README.md`, README links, `serverupdate` and `apkrelease` GitHub clients.
- The updater runs `git fetch origin` and fast-forwards, so it follows whatever `origin` points at.

## Housekeeping
- Directory is not a git repository (no `.git`), so history cannot be preserved from this copy. An empty file `Test` sits at the root.
