# Security Audit (baseline, 2026-10-25)

Static review only. No penetration testing, no dependency scan, no mobile binary analysis has been run yet. Severity is preliminary.

| ID | Severity | Finding | Evidence | Remediation | Effort |
|----|----------|---------|----------|-------------|--------|
| SEC-001 | Critical | Updater sidecar mounts `/var/run/docker.sock` (root-equivalent on host) and pulls code from git `origin`, then builds and deploys it. | `docker-compose.yml` updater service; `updater/main.go` syncRepo and `docker compose build/up` | Remove from default stack. Replace with signed release images pulled by tag, applied by a host-side script or Watchtower-style tool outside the app trust boundary. Keep rollback. | L |
| SEC-002 | High | Background location isolate stores reusable credentials (access token and best-effort full pair) in `shared_preferences`. | `app/lib/services/background_location_service.dart` (WB-002 comments), `background_credential_store.dart`; README lines 303, 557 | Use Android Keystore / iOS Keychain through native code the background service reads, plus a narrow device-scoped ingest key (see SEC-003) instead of account tokens. | M |
| SEC-003 | Info | A device ingest key mechanism already exists (migration 000024, `middleware/ingest_key.go`). Verify it is the only credential the background isolate needs. | `middleware/ingest_key_test.go` | Confirm scope, rotation, revocation. | S |
| SEC-004 | High | Default secrets in Compose: `JWT_SECRET` defaults to `change-me-in-production`, Postgres password defaults to `openfamily`. Production mode refuses the default JWT secret, development mode does not. | `docker-compose.yml`, README line 539 | Generate secrets at first run, refuse to boot with defaults unless `APP_ENV=development` explicitly. Add config validation tool. | S |
| SEC-005 | Medium | `binwiederhier/ntfy:latest` unpinned image; ntfy published on 127.0.0.1:2586. | `docker-compose.yml` | Pin versions and digests for all images. | S |
| SEC-006 | Medium | Single-family model means no cross-circle isolation tests exist yet; introducing circles raises IDOR risk. | `models.go` | Write authorization matrix tests before the schema change. | M |
| SEC-007 | Medium | Platform admin role exists (migration 000013); no documented limit on admin access to live locations. | `handlers/admin*.go` | Decide policy; audit-log all admin location reads (audit log table exists, 000011). | M |
| SEC-008 | Medium | CI and dependency scanning not seen: no CodeQL, govulncheck, gitleaks, or SBOM in workflows. | `.github/workflows/` | Add scanners to test.yml. | S |
| SEC-009 | Low | WS origin check falls back when `ALLOWED_ORIGIN` empty; confirm behavior. | `handlers/ws.go:382-390` | Read and test. | S |

## Not yet assessed
OWASP ASVS/MASVS checklists, SQL injection review of every handler, IDOR tests, TLS config, log redaction, push payload contents, account recovery abuse, SOS abuse, location spoofing.

## Acceptance for fixes
Each finding gets a GitHub issue, a regression test where feasible, and a note in the changelog.
