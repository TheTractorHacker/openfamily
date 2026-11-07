#!/usr/bin/env bash
# Renders real Flutter app screens (widget tree + fake data, no phone) to
# docs/images/app/*.png and optimises the PNGs. Needs only Docker.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/images/app
mkdir -p "$OUT"

docker run --rm --network host \
  -v openfamily-flutter-cache:/root/.pub-cache \
  -v "$PWD":/r -w /r/app \
  -e DOCS_SCREENSHOTS=1 -e DOCS_OUT=/r/$OUT \
  ghcr.io/cirruslabs/flutter:stable \
  sh -c 'flutter pub get && flutter test test/goldens/docs_screenshots_test.dart'

# Files were written by root inside the container.
docker run --rm -v "$PWD":/r alpine chown -R 1000:1000 /r

# Quantise to <=256 colours (UI screenshots keep their look, ~4x smaller).
docker run --rm -v "$PWD/$OUT":/img python:3.14 sh -c \
  'pip install -q pillow >/dev/null 2>&1 && python - <<PY
import glob
from PIL import Image
for f in sorted(glob.glob("/img/*.png")):
    im = Image.open(f).convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    im.save(f, optimize=True)
PY
chown -R 1000:1000 /img'
du -ch "$OUT"/*.png | tail -1
