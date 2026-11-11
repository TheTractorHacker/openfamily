#!/usr/bin/env bash
# Fast local Android build in Docker (nothing to install on the host).
#
# Builds an installable arm64 APK. It is signed with the DEBUG key, never with
# the release key: it can be installed on a test phone, but it is NOT
# distributable and it cannot update a phone that has the real (Play, Obtainium)
# build installed (the signatures differ; uninstall first).
#
# Fast on repeat runs because everything expensive stays between runs:
#   - Docker named volumes: Gradle (~/.gradle incl. the build cache), the pub
#     cache and the Android SDK/NDK, so nothing is downloaded twice;
#   - the app/build directory of this checkout, so Gradle and Flutter only redo
#     what changed (a Dart-only edit skips the Kotlin compile and the resource
#     steps).
# See docs/developers/build-speed.md for measured timings.
#
# Usage: scripts/dev/apk-fast.sh [options]
#   --release        R8 minified release build (default; closest to what ships)
#   --profile        profile build (no minify, faster, attachable DevTools)
#   --abi ABI        arm64 (default), arm (32-bit), both (arm + arm64), x64
#   --install        adb install -r the result when adb sees a device
#   --out DIR        copy the APK here (default: <repo>/.local-apks, git-ignored)
#   --cpus N         CPUs for the container (default 6; the host is shared)
#   --lowmem         4 GB Gradle heap instead of 6 GB
#   --no-pub         skip 'flutter pub get' (pubspec unchanged since last run)
#   --clean          flutter clean first (cold build; use if something is odd)
#   --name-version V --build-number N   pass through to Flutter
# Environment: FLUTTER_IMAGE, VOL_GRADLE, VOL_PUB, VOL_SDK override defaults.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE=release ABI=arm64 INSTALL=0 OUT="$REPO/.local-apks" CPUS=6 HEAP=6G PUB=1 CLEAN=0
BN="" BC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) MODE=release ;;
    --profile) MODE=profile ;;
    --abi) ABI="$2"; shift ;;
    --install) INSTALL=1 ;;
    --out) OUT="$2"; shift ;;
    --cpus) CPUS="$2"; shift ;;
    --lowmem) HEAP=4G ;;
    --no-pub) PUB=0 ;;
    --clean) CLEAN=1 ;;
    --name-version) BN="$2"; shift ;;
    --build-number) BC="$2"; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

case "$ABI" in
  arm64) PLAT=android-arm64; TAG=arm64-v8a ;;
  arm) PLAT=android-arm; TAG=armeabi-v7a ;;
  both) PLAT=android-arm,android-arm64; TAG=arm-arm64 ;;
  x64) PLAT=android-x64; TAG=x86_64 ;;
  *) echo "--abi must be arm64, arm, both or x64" >&2; exit 2 ;;
esac

IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
VOL_GRADLE="${VOL_GRADLE:-openfamily-gradle-lowmem}"
VOL_PUB="${VOL_PUB:-openfamily-flutter-cache}"
VOL_SDK="${VOL_SDK:-openfamily-sdk-lowmem}"
mkdir -p "$OUT"
START=$(date +%s)

echo "== apk-fast: $MODE $TAG, ${CPUS} cpus, heap $HEAP (DEBUG-SIGNED, not distributable)" >&2
docker run --rm --cpus="$CPUS" --network host \
  -v "$VOL_PUB":/root/.pub-cache -v "$VOL_GRADLE":/root/.gradle -v "$VOL_SDK":/opt/android-sdk-linux \
  -v "$REPO":/r -w /r/app \
  -e ORG_GRADLE_PROJECT_OPENFAMILY_ALLOW_DEBUG_SIGNING=true \
  -e MODE="$MODE" -e PLAT="$PLAT" -e PUB="$PUB" -e CLEAN="$CLEAN" -e HEAP="$HEAP" \
  -e BN="$BN" -e BC="$BC" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash -c '
set -euo pipefail
t() { echo "-- $(date +%T) $*" >&2; }
# User-level Gradle settings live in the volume and win over the repo file:
# bigger heap, parallel, build cache on. The repo defaults stay conservative.
cat > /root/.gradle/gradle.properties <<P
org.gradle.jvmargs=-Xmx${HEAP} -XX:MaxMetaspaceSize=2G -XX:+UseParallelGC
org.gradle.parallel=true
org.gradle.caching=true
kotlin.daemon.jvmargs=-Xmx2G
P
trap "chown -R \$HOST_UID:\$HOST_GID /r/app/build /r/app/.dart_tool /r/app/android/.gradle /r/app/android/local.properties 2>/dev/null || true" EXIT
[ "$CLEAN" = 1 ] && { t flutter clean; flutter clean >/dev/null; }
if [ "$PUB" = 1 ]; then t pub get; flutter pub get >/dev/null; fi
ARGS=(--"$MODE" --target-platform "$PLAT" --no-pub)
[ -n "$BN" ] && ARGS+=(--build-name="$BN")
[ -n "$BC" ] && ARGS+=(--build-number="$BC")
t "flutter build apk ${ARGS[*]}"
flutter build apk "${ARGS[@]}" 2>&1 | grep -Ev "^(Downloading|\s*$)" | tail -25
' || { echo "BUILD FAILED" >&2; exit 1; }

SRC="$REPO/app/build/app/outputs/flutter-apk/app-$MODE.apk"
VER="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$REPO/app/pubspec.yaml" | head -1)"
DST="$OUT/orbitly-${VER:-dev}-${MODE}-${TAG}-DEBUG-SIGNED.apk"
cp "$SRC" "$DST"
echo "== built in $(( $(date +%s) - START ))s: $DST ($(du -h "$DST" | cut -f1)), DEBUG-SIGNED" >&2

if [ "$INSTALL" = 1 ]; then
  if ! command -v adb >/dev/null; then echo "adb not found; copy $DST to the phone" >&2; exit 0; fi
  if [ -z "$(adb devices | sed 1d | grep -w device || true)" ]; then echo "no authorised adb device; APK is at $DST" >&2; exit 0; fi
  adb install -r "$DST" || { echo "install failed. If it says INSTALL_FAILED_UPDATE_INCOMPATIBLE, uninstall the other build first (adb uninstall app.openfamily); that loses its local data." >&2; exit 1; }
fi
echo "$DST"
