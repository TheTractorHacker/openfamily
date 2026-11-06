#!/usr/bin/env bash
# Run the k6 ingestion + WebSocket load test (scripts/load/ingest-ws.js) with a
# pinned k6 image. NON-PRODUCTION targets only: it writes synthetic points.
# Env: BASE_URL, TOKEN, DEVICE_ID (or TOKENS/DEVICE_IDS), VUS, WS_VUS, DURATION, INTERVAL
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BASE_URL:?set BASE_URL (non-production)}"
case "$BASE_URL" in *openfamily.app*|*prod*) echo "refusing a production-looking BASE_URL" >&2; exit 2 ;; esac
exec docker run --rm --network host -i \
  -e BASE_URL -e TOKEN -e DEVICE_ID -e TOKENS -e DEVICE_IDS -e VUS -e WS_VUS -e DURATION -e INTERVAL \
  -v "$PWD/scripts/load:/s:ro" \
  grafana/k6:1.4.0@sha256:6a3ee54ac0e9ff5527923f6295257453dd88012f32f40dadf0eb1b638cbb21c7 run /s/ingest-ws.js
