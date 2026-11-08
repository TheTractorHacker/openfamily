#!/usr/bin/env bash
# APK size report, CI-friendly.
#
#   scripts/perf/apk-size-report.sh <apk> [--tsv]
#
# Prints the APK's download size and a breakdown by component (native libs
# per ABI, Dart AOT snapshot, Flutter assets, dex, resources, other) from the
# zip directory alone: no SDK tools needed. --tsv prints one "component<TAB>
# bytes" line per row for trend charts. Pair with scripts/apk-size-budget.sh,
# which enforces the growth limit against scripts/apk-size-baseline.txt.
#
# Budgets (docs/design/OPTIMIZATION_ARCHITECTURE.md): arm64 release APK
# <= 60 MB download, libapp.so (Dart AOT) <= 14 MB, classes*.dex <= 10 MB.
set -euo pipefail

apk="${1:?usage: apk-size-report.sh <apk> [--tsv]}"
mode="${2:-}"
command -v unzip >/dev/null || { echo "unzip not found" >&2; exit 2; }

total="$(stat -c %s "$apk")"

# unzip -l columns: Length Date Time Name (compressed sizes are not listed;
# the uncompressed length is what the installer stores for native libs, which
# are stored uncompressed and page-aligned in a Flutter release APK anyway).
sum() { awk -v pat="$1" '$4 ~ pat {s+=$1} END {printf "%d", s+0}'; }
listing="$(unzip -l "$apk" | awk 'NR>3 && $1 ~ /^[0-9]+$/ && $4 != ""')"

declare -A rows
rows[lib/arm64-v8a]="$(printf '%s\n' "$listing" | sum '^lib/arm64-v8a/')"
rows[lib/armeabi-v7a]="$(printf '%s\n' "$listing" | sum '^lib/armeabi-v7a/')"
rows[lib/x86_64]="$(printf '%s\n' "$listing" | sum '^lib/x86_64/')"
rows[libapp.so(dart-aot)]="$(printf '%s\n' "$listing" | sum '/libapp[.]so$')"
rows[libflutter.so(engine)]="$(printf '%s\n' "$listing" | sum '/libflutter[.]so$')"
rows[flutter_assets]="$(printf '%s\n' "$listing" | sum '^assets/flutter_assets/')"
rows[classes.dex]="$(printf '%s\n' "$listing" | sum '^classes[0-9]*[.]dex$')"
rows[res+resources.arsc]="$(printf '%s\n' "$listing" | sum '^(res/|resources[.]arsc$)')"
rows[META-INF]="$(printf '%s\n' "$listing" | sum '^META-INF/')"
uncompressed="$(printf '%s\n' "$listing" | awk '{s+=$1} END {printf "%d", s+0}')"

if [ "$mode" = "--tsv" ]; then
  printf 'apk_bytes\t%s\n' "$total"
  printf 'uncompressed_bytes\t%s\n' "$uncompressed"
  for k in "${!rows[@]}"; do printf '%s\t%s\n' "$k" "${rows[$k]}"; done | sort
  exit 0
fi

mb() { awk -v b="$1" 'BEGIN {printf "%.1f MB", b/1048576}'; }
echo "APK: $apk"
echo "download size (file): $(mb "$total")   uncompressed: $(mb "$uncompressed")"
printf '%-26s %12s\n' component uncompressed
for k in "lib/arm64-v8a" "lib/armeabi-v7a" "lib/x86_64" "libapp.so(dart-aot)" "libflutter.so(engine)" "flutter_assets" "classes.dex" "res+resources.arsc" "META-INF"; do
  v="${rows[$k]}"
  [ "$v" = "0" ] && continue
  printf '%-26s %12s\n' "$k" "$(mb "$v")"
done
echo
echo "Largest 12 entries:"
printf '%s\n' "$listing" | sort -k1,1nr | head -12 | awk '{printf "  %8.1f MB  %s\n", $1/1048576, $4}'
