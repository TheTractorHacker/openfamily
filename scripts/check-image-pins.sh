#!/usr/bin/env bash
# Fail if any container image is floating: ":latest", no tag, or a tag without
# an @sha256 digest. Checks docker-compose.yml and every Dockerfile FROM.
# The locally built openfamily-api:local image is exempt. Renovate/Dependabot
# (.github/dependabot.yml) proposes digest bumps.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=0
check() { # $1 file:line  $2 image ref
  local ref="$2"
  case "$ref" in openfamily-api:local|openfamily-backup:local|scratch|build|'${'*) return 0 ;; esac
  if [[ "$ref" == *":latest"* ]] || [[ "$ref" != *"@sha256:"* ]]; then
    echo "unpinned image at $1: $ref" >&2; bad=1
  fi
}
while IFS=: read -r f n rest; do
  ref="$(echo "$rest" | sed -E 's/^ *image: *//; s/ +#.*//')"
  check "$f:$n" "$ref"
done < <(grep -nE '^\s*image:' docker-compose.yml | sed 's/^/docker-compose.yml:/')
while IFS= read -r f; do
  stages=""
  while IFS=: read -r n line; do
    ref="$(echo "$line" | sed -E 's/^FROM +(--platform=[^ ]+ +)?//I; s/ +AS +.*//I')"
    case " $stages " in *" $ref "*) continue ;; esac   # FROM <earlier stage>
    check "$f:$n" "$ref"
    st="$(echo "$line" | sed -nE 's/.* AS +([^ ]+).*/\1/Ip')"; [ -n "$st" ] && stages="$stages $st"
  done < <(grep -nEi '^FROM ' "$f")
done < <(find . -name 'Dockerfile*' -not -name '*.dockerignore' -not -path '*/node_modules/*' -not -path './app/build/*')
[ "$bad" = 0 ] && echo "image pins OK"
exit "$bad"
