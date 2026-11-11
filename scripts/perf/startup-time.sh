#!/usr/bin/env bash
# Cold-start time on a connected Android device, CI-friendly.
#
#   scripts/perf/startup-time.sh [runs=10] [package=app.openfamily] [activity=.MainActivity]
#
# For each run: force-stop the app, drop the page cache if the device is
# rooted (ignored otherwise), then `am start -W` and read TotalTime (process
# start to first frame, what Play's "slow cold start" vital measures, cold
# >= 5 s). Prints every sample, then median and p90, and a BUDGET line that
# exits 1 when the median exceeds STARTUP_BUDGET_MS (default 2000, the
# docs/design/OPTIMIZATION_ARCHITECTURE.md mid-range target). Needs adb and
# one connected device; exits 2 (skipped) when there is none, so the step is
# safe in a workflow without a device.
#
# Flutter's own first-frame number (engine boot + main() to first frame) is
# on the hidden Performance screen (docs/performance.md); use both: this one
# is what the OS and the store see.
set -euo pipefail

runs="${1:-10}"
pkg="${2:-app.openfamily}"
act="${3:-.MainActivity}"
budget="${STARTUP_BUDGET_MS:-2000}"

if ! command -v adb >/dev/null 2>&1; then echo "adb not found; skipped" >&2; exit 2; fi
if [ "$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)" -lt 1 ]; then
  echo "no device connected; skipped" >&2; exit 2
fi

model="$(adb shell getprop ro.product.model | tr -d '\r')"
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
echo "device: $model (API $sdk), package $pkg, $runs cold starts"
samples=()
for i in $(seq 1 "$runs"); do
  adb shell am force-stop "$pkg"
  adb shell "echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1 || true
  sleep 2
  out="$(adb shell am start -W -n "$pkg/$act" 2>/dev/null | tr -d '\r')"
  ms="$(printf '%s\n' "$out" | awk -F: '/^TotalTime/ {gsub(/ /,"",$2); print $2}')"
  if [ -z "$ms" ]; then echo "run $i: no TotalTime in am output" >&2; continue; fi
  samples+=("$ms")
  echo "run $i: ${ms} ms"
done
adb shell am force-stop "$pkg"

n="${#samples[@]}"
[ "$n" -gt 0 ] || { echo "no samples" >&2; exit 1; }
sorted="$(printf '%s\n' "${samples[@]}" | sort -n)"
median="$(printf '%s\n' "$sorted" | awk -v n="$n" 'NR==int((n+1)/2) {print; exit}')"
p90="$(printf '%s\n' "$sorted" | awk -v n="$n" 'NR==int(n*0.9+0.999) {print; exit}')"
echo "cold start TotalTime: median ${median} ms, p90 ${p90} ms (n=$n)"
if [ "$median" -gt "$budget" ]; then
  echo "BUDGET EXCEEDED: median ${median} ms > ${budget} ms" >&2
  exit 1
fi
echo "BUDGET OK: median ${median} ms <= ${budget} ms"
