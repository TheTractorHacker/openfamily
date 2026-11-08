#!/usr/bin/env bash
# Targeted tests in Docker with shared caches (nothing to install on the host).
#
#   scripts/dev/test-fast.sh flutter [flutter test args or files]
#       e.g.  scripts/dev/test-fast.sh flutter test/chat
#             scripts/dev/test-fast.sh flutter --name "offline queue"
#             scripts/dev/test-fast.sh flutter --shard-index 0 --total-shards 3
#       Runs 'flutter test --concurrency N' (N = --cpus value, default 6).
#   scripts/dev/test-fast.sh analyze
#       flutter analyze --no-fatal-infos (CI also fails on warnings).
#   scripts/dev/test-fast.sh go [go test args / packages]
#       e.g.  scripts/dev/test-fast.sh go ./internal/chat/...
#       Starts a throwaway TimescaleDB (fsync off), migrates it, runs
#       'go test -p 1 -count=1', then removes the container. DB tests need -p 1
#       because packages share the one database.
#   scripts/dev/test-fast.sh go-up | go-down
#       Keep one migrated DB running between runs (skips ~25 s of startup):
#       run go-up once, then 'go' reuses it, go-down removes it.
#
# Environment: CPUS (default 6; the host is shared), FLUTTER_IMAGE, GO_IMAGE.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CPUS="${CPUS:-6}"
FLUTTER_IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
GO_IMAGE="${GO_IMAGE:-golang:1.27}"
DB_IMAGE="timescale/timescaledb-ha:pg16.15-ts2.31.0"
KEEP=openfamily-testfast-db
KEEP_PORT=55432
[ $# -ge 1 ] || { sed -n '2,20p' "$0"; exit 2; }
cmd="$1"; shift

fix_owner() { docker run --rm -v "$REPO":/r alpine chown -R "$(id -u):$(id -g)" /r/app/.dart_tool /r/app/build /r/backend 2>/dev/null || true; }

start_db() { # name port
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" -p "127.0.0.1:$2:5432" -e POSTGRES_PASSWORD=t -e POSTGRES_DB=t \
    "$DB_IMAGE" -c fsync=off -c synchronous_commit=off -c full_page_writes=off >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$1" pg_isready -U postgres -d t >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "database did not start" >&2; return 1
}

go_run() { # port args...
  local port="$1"; shift
  docker run --rm --cpus="$CPUS" --network host \
    -v openfamily-go-cache:/go -v "$REPO":/r -w /r/backend \
    -e TEST_DATABASE_URL="postgres://postgres:t@127.0.0.1:$port/t?sslmode=disable" \
    "$GO_IMAGE" sh -c 'go run ./cmd/migrate && go test -p 1 -count=1 -timeout 30m "$@"' sh "$@"
}

set +e # keep the test exit code; the cases below report it
case "$cmd" in
  flutter)
    docker run --rm --cpus="$CPUS" -v openfamily-flutter-cache:/root/.pub-cache -v "$REPO":/r -w /r/app \
      "$FLUTTER_IMAGE" bash -c 'flutter pub get >/dev/null && flutter test --no-pub --concurrency '"$CPUS"' "$@"' bash "$@"
    rc=$?; fix_owner; exit $rc ;;
  analyze)
    docker run --rm --cpus="$CPUS" -v openfamily-flutter-cache:/root/.pub-cache -v "$REPO":/r -w /r/app \
      "$FLUTTER_IMAGE" bash -c 'flutter pub get >/dev/null && flutter analyze --no-pub --no-fatal-infos'
    rc=$?; fix_owner; exit $rc ;;
  go-up) start_db "$KEEP" "$KEEP_PORT" || exit 1; echo "database up on 127.0.0.1:$KEEP_PORT; 'go' will reuse it" ;;
  go-down) docker rm -f "$KEEP" >/dev/null && echo removed ;;
  go)
    [ $# -ge 1 ] || set -- ./...
    if docker ps --format '{{.Names}}' | grep -qx "$KEEP"; then
      go_run "$KEEP_PORT" "$@"; rc=$?
    else
      name="openfamily-testfast-$$"; port=$((56000 + $$ % 2000))
      trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
      start_db "$name" "$port" || exit 1
      go_run "$port" "$@"; rc=$?
    fi
    exit $rc ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
