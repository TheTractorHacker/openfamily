#!/usr/bin/env bash
# Builds the store listing images into dist/store-assets (gitignored) from the REAL
# app widgets rendered with the fictional "Rivera Family" demo data. Needs only Docker.
#
#   scripts/store-assets.sh                 render screens + compose everything
#   scripts/store-assets.sh --compose-only  reuse dist/store-assets/raw (after a render)
#
# Optional: put real watch captures in dist/store-assets/raw-watch/ first
#   wear-*.png        (Wear OS, any size, square or round crop)
#   applewatch-*.png  (Apple Watch simulator captures)
# and they are resized into the store slots. See docs/release/STORE_ASSETS.md.
#
# On a shared host run it through the heavy-job gate:  HEAVY=/tmp/orbitly-heavy/heavy.sh scripts/store-assets.sh
set -euo pipefail
cd "$(dirname "$0")/.."

run() { if [ -n "${HEAVY:-}" ]; then "$HEAVY" "$@"; else "$@"; fi; }

OUT=dist/store-assets
mkdir -p "$OUT"

if [ "${1:-}" != "--compose-only" ]; then
  rm -rf "$OUT/raw"
  run docker run --rm --cpus=4 --network host \
    -v openfamily-flutter-cache:/root/.pub-cache \
    -v "$PWD":/r -w /r/app \
    -e STORE_ASSETS=1 -e STORE_RAW=/r/$OUT/raw \
    ghcr.io/cirruslabs/flutter:stable \
    sh -c 'flutter pub get && flutter test test/goldens/store_screenshots_test.dart'
  # Files were written by root inside the container.
  docker run --rm -v "$PWD":/r alpine chown -R "$(id -u):$(id -g)" /r/dist /r/app
fi

[ -f "$OUT/raw/manifest.json" ] || { echo "no $OUT/raw/manifest.json: run without --compose-only first" >&2; exit 1; }

run docker run --rm --cpus=2 -v "$PWD":/r -w /r python:3.14 sh -c '
  pip install -q pillow >/dev/null 2>&1 &&
  python scripts/store-assets/compose.py --raw dist/store-assets/raw --out dist/store-assets \
    --brand assets/brand --watch dist/store-assets/raw-watch &&
  chown -R '"$(id -u):$(id -g)"' dist'

echo
echo "Done. Read $OUT/README.md for what to upload where."
echo "These are RENDERS of the real widget tree, not device captures: see docs/release/STORE_ASSETS.md."
