#!/usr/bin/env bash
# Server ingest benchmarks against a throwaway TimescaleDB, all in Docker.
#
#   scripts/perf/ingest-bench.sh [count=3] [benchtime=200x]
#
# Starts timescale/timescaledb-ha (fsync off: this measures handler + SQL
# work, not disk latency), migrates it with db.Migrate through a temporary
# cmd/_mig helper, runs BenchmarkIngest* (internal/handlers) and the trips
# pipeline benchmarks (internal/trips), prints the results and removes the
# container and the helper. Output is plain `go test -bench` text; keep two
# runs and compare them with benchstat (>= 10 counts for a verdict).
#
# Shared-host etiquette: wrap in /tmp/orbitly-heavy/heavy.sh when that exists.
set -euo pipefail
cd "$(dirname "$0")/../.."

count="${1:-3}"
benchtime="${2:-200x}"
name="orbitly-ingest-bench-$$"
port="$(( 55000 + RANDOM % 5000 ))"
goimg="${GO_IMAGE:-golang:1.27}"
pgimg="${PG_IMAGE:-timescale/timescaledb-ha:pg16.15-ts2.31.0}"
url="postgres://postgres:postgres@127.0.0.1:${port}/postgres?sslmode=disable"
mig="backend/cmd/_mig"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$mig"
  docker run --rm -v "$PWD:/r" alpine chown -R "$(id -u):$(id -g)" /r/backend >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --rm --name "$name" --cpus=2 -e POSTGRES_PASSWORD=postgres \
  -p "127.0.0.1:${port}:5432" "$pgimg" -c fsync=off -c synchronous_commit=off >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done

mkdir -p "$mig"
cat > "$mig/main.go" <<'EOF'
package main

import (
	"log"
	"os"

	"github.com/TheTractorHacker/openfamily/backend/internal/db"
)

func main() {
	if err := db.Migrate(os.Getenv("TEST_DATABASE_URL")); err != nil {
		log.Fatal(err)
	}
}
EOF

gorun() {
  docker run --rm --cpus=4 --network host -v openfamily-go-cache:/go -v "$PWD:/r" -w /r/backend \
    -e TEST_DATABASE_URL="$url" "$goimg" "$@"
}
gorun go run ./cmd/_mig
echo "== ingest benchmarks (handler + Postgres, fsync off) =="
gorun go test ./internal/handlers -run '^$' -bench 'BenchmarkIngest' -benchmem -count "$count" -benchtime "$benchtime"
echo "== trips pipeline (pure CPU) =="
gorun go test ./internal/trips -run '^$' -bench . -benchmem -count "$count"
