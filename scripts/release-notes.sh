#!/usr/bin/env bash
# Body text of the GitHub release for an app version: docs/release/notes/<version>.md when it exists, otherwise that
# version's section of docs/CHANGELOG.md, so a release never goes out with empty notes. Usage:
#   scripts/release-notes.sh 0.26.29            print the notes
#   scripts/release-notes.sh --check 0.26.29    exit 1 if the notes or the Play text are missing or too long
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
V="${1:?usage: release-notes.sh [--check] <version, e.g. 0.26.29>}"
V="${V#v}"
F="docs/release/notes/$V.md"
P="docs/release/notes/$V.play.txt"
if [ "$CHECK" = 1 ]; then
  [ -s "$F" ] || { echo "missing $F" >&2; exit 1; }
  [ -s "$P" ] || { echo "missing $P" >&2; exit 1; }
  n=$(wc -m < "$P")
  [ "$n" -le 500 ] || { echo "$P is $n characters (Play allows 500)" >&2; exit 1; }
  echo "release notes OK for $V ($n characters of Play text)"
  exit 0
fi
if [ -s "$F" ]; then
  cat "$F"
else
  awk -v h="## v$V " 'index($0,h)==1{p=1;next} p&&/^## v/{exit} p' docs/CHANGELOG.md
fi
