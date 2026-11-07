#!/usr/bin/env bash
# Regenerates every screenshot used by the documentation.
#   web  (docs/images/web):  throwaway docker compose stack from THIS checkout
#                            (own project name, own ports, own volumes and image
#                            tag; never your real stack), seeded with the made-up
#                            "Rivera Family", captured with Playwright in Docker.
#   app  (docs/images/app):  Flutter widget-tree renders (scripts/docs-screenshots-app.sh).
# Usage: scripts/docs-screenshots.sh [web|app|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."
what="${1:-all}"
PROJECT=ofdocs-shots
PORT="${DOCS_SHOTS_PORT:-18490}"
PW_IMAGE="${PW_IMAGE:-mcr.microsoft.com/playwright:v1.49.0-noble}"

web() {
  tmp="$(mktemp -d)"
  local pass="Docs-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  cat > "$tmp/env" <<EOF
POSTGRES_PASSWORD=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
JWT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
API_PORT=$PORT
API_BIND=127.0.0.1
PLATFORM_ADMIN_EMAIL=maria@example.com
PLATFORM_ADMIN_PASSWORD=$pass
ADMIN_LOCATION_ACCESS=true
APP_ENV=development
SITE_ADDRESS=:80
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo demo)
EOF
  cat > "$tmp/override.yml" <<EOF
services:
  api:
    image: ofdocs-shots-api:local
    container_name: ofdocs-shots-api
  postgres:
    container_name: ofdocs-shots-db
EOF
  dc=(docker compose -p "$PROJECT" --env-file "$tmp/env" -f docker-compose.yml -f "$tmp/override.yml")
  cleanup() { "${dc[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; docker rmi ofdocs-shots-api:local >/dev/null 2>&1 || true; rm -rf "$tmp"; }
  trap cleanup EXIT
  "${dc[@]}" up -d --build api postgres
  for _ in $(seq 1 90); do curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 2; done
  curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null
  docker run --rm --network host -v "$PWD/scripts/docs-screenshots:/s:ro" -w /s node:22 \
    node seed.mjs "http://127.0.0.1:$PORT" maria@example.com "$pass"
  mkdir -p docs/images/web
  docker run --rm --network host -v "$PWD:/r" -w /tmp "$PW_IMAGE" sh -c "
    npm init -y >/dev/null && npm i playwright@1.49.0 >/dev/null 2>&1 &&
    cp /r/scripts/docs-screenshots/shoot.mjs . &&
    node shoot.mjs http://127.0.0.1:$PORT maria@example.com '$pass' /r/docs/images/web"
  optimise docs/images/web
}

# Quantise PNGs to keep the repository and the server image small.
optimise() {
  docker run --rm -v "$PWD/$1:/img" python:3.14 sh -c '
    pip install -q pillow >/dev/null 2>&1 &&
    python - <<PY
import glob
from PIL import Image
for f in glob.glob("/img/*.png"):
    im = Image.open(f).convert("RGB")
    im.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(f, optimize=True)
PY'
  docker run --rm -v "$PWD:/r" alpine chown -R "$(id -u):$(id -g)" /r/docs/images
}

case "$what" in
  web) web ;;
  app) scripts/docs-screenshots-app.sh ;;
  all) web; scripts/docs-screenshots-app.sh ;;
  *) echo "usage: $0 [web|app|all]" >&2; exit 2 ;;
esac
echo "done. Review docs/images, then run scripts/docs-check.sh --fix"
