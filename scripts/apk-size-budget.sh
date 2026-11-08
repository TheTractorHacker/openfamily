#!/usr/bin/env bash
# Size budget check for the arm64 APK.
#
#   scripts/apk-size-budget.sh <apk> [baseline-file] [max-growth-percent]
#
# Compares the APK's byte size with the number recorded in the baseline file
# (default scripts/apk-size-baseline.txt, one integer: bytes) and exits 1 when
# it grew by more than max-growth-percent (default 5). Exits 0 with a notice
# when no baseline exists yet. After an intended change, update the baseline:
#   scripts/apk-size-budget.sh <apk> --record
set -euo pipefail

apk="${1:?usage: apk-size-budget.sh <apk> [baseline-file|--record] [max-growth-percent]}"
base="${2:-$(dirname "$0")/apk-size-baseline.txt}"
max="${3:-5}"

size="$(stat -c %s "$apk")"
if [ "$base" = "--record" ]; then
  echo "$size" > "$(dirname "$0")/apk-size-baseline.txt"
  echo "Recorded baseline: $size bytes"
  exit 0
fi
if [ ! -s "$base" ]; then
  echo "No size baseline at $base; this build is $size bytes. Record it with --record."
  exit 0
fi
old="$(tr -d '[:space:]' < "$base")"
limit=$(( old + old * max / 100 ))
printf 'APK size: %s bytes (baseline %s, limit +%s%% = %s)\n' "$size" "$old" "$max" "$limit"
if [ "$size" -gt "$limit" ]; then
  echo "SIZE BUDGET EXCEEDED: grew by $(( (size - old) * 100 / old ))%" >&2
  exit 1
fi
echo "Within budget."
