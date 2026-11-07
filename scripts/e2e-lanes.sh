#!/usr/bin/env bash
# Real-server interop test of the processing lanes (docs/testing/E2E_LANES.md).
#
# Starts, all in Docker and on throwaway ports/volumes:
#   * a TimescaleDB/PostGIS database (fsync off),
#   * the REAL Go server binary built from backend/ (it migrates itself),
#   * the REAL e2ee-bridge binary (used by the test as the server device),
# and runs app/test/e2e_real_server/ (the real Dart phone code over real HTTP).
# Nothing here touches your compose stack. Needs only docker and network access for
# the first image/module download. Usage: scripts/e2e-lanes.sh [flutter test args...]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
RUN="${E2E_RUN:-$(date +%s)-$$}"   # E2E_RUN + E2E_KEEP=1: keep the stack between runs (development)
DB="of-e2e-db-$RUN"
API="of-e2e-api-$RUN"
DB_PORT="${E2E_DB_PORT:-55433}"
API_PORT="${E2E_API_PORT:-18089}"
CACHE="${E2E_CACHE:-$HOME/.cache/openfamily-e2e}"
WORK="${TMPDIR:-/tmp}/of-e2e.$RUN"; mkdir -p "$WORK"
GO_IMG="${E2E_GO_IMAGE:-golang:1.27}"
FLUTTER_IMG="${E2E_FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
DB_IMG="${E2E_DB_IMAGE:-timescale/timescaledb-ha:pg16.15-ts2.31.0}"
DB_PASS="e2e-$RUN"
JWT_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
INGEST_TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
DB_URL="postgres://postgres:$DB_PASS@127.0.0.1:$DB_PORT/openfamily?sslmode=disable"
mkdir -p "$CACHE"/{gomod,gobuild,pub} "$WORK/bin"
# A kept stack (E2E_KEEP) must be reused with the secrets it was started with.
if [ -f "$WORK/secrets.sh" ]; then . "$WORK/secrets.sh"; else printf 'DB_PASS=%s\nJWT_SECRET=%s\nINGEST_TOKEN=%s\n' "$DB_PASS" "$JWT_SECRET" "$INGEST_TOKEN" >"$WORK/secrets.sh"; fi
DB_URL="postgres://postgres:$DB_PASS@127.0.0.1:$DB_PORT/openfamily?sslmode=disable"

cleanup() {
  rc=$?
  if [ -s "$WORK/api.log.keep" ] || [ $rc -ne 0 ]; then docker logs "$API" >"$WORK/api.log" 2>&1 || true; fi
  [ "${E2E_KEEP:-0}" = 1 ] || docker rm -f "$API" "$DB" >/dev/null 2>&1 || true
  rm -rf "$ROOT/backend/cmd/_e2eprobe"
  # Containers ran as root: give the tree back to the invoking user.
  docker run --rm -v "$ROOT:/r" "$GO_IMG" chown -R "$(id -u):$(id -g)" /r/app /r/backend /r/scripts /r/docs >/dev/null 2>&1 || true
  [ $rc -ne 0 ] && echo "e2e-lanes: FAILED (rc=$rc); server log: $WORK/api.log" >&2
  [ $rc -eq 0 ] && [ "${E2E_KEEP:-0}" != 1 ] && rm -rf "$WORK"
  if [ -f "$WORK/api.log" ] && grep -E 'xyzzy-secret|plugh-secret|quux-secret' "$WORK/api.log" >/dev/null 2>&1; then
  echo "e2e-lanes: a chat message text appears in the server log" >&2; rc=1
fi
exit $rc
}
trap cleanup EXIT

E2E_REUSED=0
if docker ps --format '{{.Names}}' | grep -qx "$API"; then E2E_REUSED=1; else
echo "== building server, e2ee-bridge, probe"
mkdir -p "$ROOT/backend/cmd/_e2eprobe"
cp scripts/e2e-lanes/probe.go "$ROOT/backend/cmd/_e2eprobe/main.go"
docker run --rm --network host -v "$ROOT/backend:/src" -v "$WORK/bin:/out" \
  -v "$CACHE/gomod:/go/pkg/mod" -v "$CACHE/gobuild:/root/.cache/go-build" -w /src \
  -e CGO_ENABLED=0 "$GO_IMG" sh -c \
  'go build -trimpath -o /out/server ./cmd/server && go build -trimpath -o /out/e2ee-bridge ./cmd/e2ee-bridge && go build -trimpath -o /out/e2eprobe ./cmd/_e2eprobe'
rm -rf "$ROOT/backend/cmd/_e2eprobe"

echo "== starting database ($DB)"
docker run -d --name "$DB" --network host -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB=openfamily \
  -e PGPORT="$DB_PORT" "$DB_IMG" -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c port="$DB_PORT" >/dev/null
for _ in $(seq 1 120); do
  docker exec "$DB" psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d openfamily -tAc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$DB" psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d openfamily -tAc 'select 1' >/dev/null

echo "== starting server ($API)"
docker run -d --name "$API" --network host -v "$WORK/bin:/bin-e2e:ro" \
  -e HTTP_ADDR="127.0.0.1:$API_PORT" -e DATABASE_URL="$DB_URL" -e JWT_SECRET="$JWT_SECRET" \
  -e APP_ENV=development -e INSECURE_HTTP=true -e ACCESS_TOKEN_TTL=24h -e GEOCODER_URL= -e GEOCODER_FALLBACK_URL= \
  -e E2EE_SERVER_INGEST_TOKEN="$INGEST_TOKEN" -e ADMIN_LOCATION_ACCESS=false \
  "$GO_IMG" /bin-e2e/server >/dev/null
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$API_PORT/healthz" >/dev/null

fi
if [ "${E2E_REUSED:-0}" = 1 ]; then # in-memory rate limits: a restart gives a clean slate
  docker exec "$DB" psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d openfamily -qc "DELETE FROM e2ee_server_device" >/dev/null
  docker restart "$API" >/dev/null
  for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1 && break; sleep 1; done
fi
echo "== running the Dart tests"
set +e
docker run --rm --network host --name "of-e2e-flutter-$RUN" \
  -v "$ROOT:/work" -v "$CACHE/pub:/root/.pub-cache" -w /work/app \
  -e E2E_REQUIRE_SIDECAR="${E2E_REQUIRE_SIDECAR:-0}" -e E2E_BASE_URL="http://127.0.0.1:$API_PORT" -e E2E_INGEST_TOKEN="$INGEST_TOKEN" \
  -e E2E_BRIDGE_BIN=/e2e-bin/e2ee-bridge -e E2E_PROBE_BIN=/e2e-bin/e2eprobe -e E2E_DATABASE_URL="$DB_URL" \
  -v "$WORK/bin:/e2e-bin:ro" \
  "$FLUTTER_IMG" sh -c 'git config --global --add safe.directory "*" >/dev/null 2>&1; flutter pub get >/dev/null 2>&1 && flutter test "$@"' sh "${@:-test/e2e_real_server/}"
rc=$?
set -e
# Audit: the server log must not contain any coordinate the test marks as private.
docker logs "$API" >"$WORK/api.log" 2>&1 || true
if [ -f "$WORK/api.log" ] && grep -E '41\.31[45]' "$WORK/api.log" >/dev/null 2>&1; then
  echo "e2e-lanes: a phone-line coordinate appears in the server log" >&2; rc=1
fi
if [ -f "$WORK/api.log" ] && grep -E 'xyzzy-secret|plugh-secret|quux-secret' "$WORK/api.log" >/dev/null 2>&1; then
  echo "e2e-lanes: a chat message text appears in the server log" >&2; rc=1
fi
exit $rc
