#!/usr/bin/env bash
# Real end-to-end scenarios against a THROWAWAY Orbitly stack, with the app's own Dart crypto / E2EE client
# in a headless `flutter test` (docs/developers/dev-stack.md). No Android emulator, phone or Xcode involved.
#
#   scripts/dev/e2e.sh                 fresh stack, all scenario files, stack removed afterwards
#   scripts/dev/e2e.sh auth            only scenario (a)         (auth_refresh_test.dart)
#   scripts/dev/e2e.sh lanes           only scenarios (b)-(d)    (lanes_stack_test.dart)
#   scripts/dev/e2e.sh conn            only scenario (e)         (connections_test.dart)
#   scripts/dev/e2e.sh --keep ...      reuse the stack of the last --keep run and leave it running
#
# It uses its OWN stack (compose project orbitly-e2e-<tag>, state under $TMPDIR/orbitly-e2e-<tag>-stack-<uid>,
# image openfamily-api:devstack-<tag>; <tag> is a hash of this checkout's path), separate from the `dev-stack.sh`
# development stack and from every other worktree's, and never touches the production stack. Two runs from the
# SAME checkout cannot overlap: the second fails fast on a lock. A fresh stack is the default
# because the lanes scenario needs the built-in server key unpinned (one server key per server; a previous
# run's key belongs to a phone that no longer exists). With --keep the lanes scenario only works on a
# stack nobody has approved a server key on yet.
#
# Scenarios that need a feature still being built are written as EXPECTED-FAILING checks: they must fail
# today and fail the run ("now passes") the day the feature lands. E2E_XFAIL=skip skips them instead.
#
# The API image is built from the working tree on every run (docker layer cache: seconds when nothing changed), so a
# green run always means THIS tree. E2E_NO_BUILD=1 reuses the image of the last build on purpose.
# E2E_STACK_DIR / E2E_STACK_PROJECT override the names; DEV_STACK_* from your shell are ignored on purpose.
#
# Exit status: 0 only when every file passed. Server logs of a failed run stay in $STATE/logs.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Never inherit the names of a development stack from the shell.
unset DEV_STACK_PROJECT DEV_STACK_DIR DEV_STACK_IMAGE DEV_API_PORT DEV_DB_PORT
export DEV_STACK_KIND=e2e
[ -z "${E2E_STACK_PROJECT:-}" ] || export DEV_STACK_PROJECT="$E2E_STACK_PROJECT"
[ -z "${E2E_STACK_DIR:-}" ] || export DEV_STACK_DIR="$E2E_STACK_DIR"
STACK="$REPO/scripts/dev/dev-stack.sh"
STATE="$("$STACK" state-dir)"
PROJECT="$("$STACK" project)"

keep=0
want=()
for a in "$@"; do
  case "$a" in
    --keep) keep=1 ;;
    auth|lanes|conn) want+=("$a") ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "e2e: unknown argument '$a'" >&2; exit 2 ;;
  esac
done
[ ${#want[@]} -gt 0 ] || want=(auth lanes conn)

# One run per checkout: a second run would `down -v` the first one's stack mid-test.
LOCK="${TMPDIR:-/tmp}/$(basename "$STATE").lock"
exec 9>"$LOCK"
if ! flock -n 9; then echo "e2e: another e2e.sh run from this checkout holds $LOCK (project $PROJECT); wait for it or stop it" >&2; exit 3; fi

STREAM_PIDS=()
cleanup() {
  local rc=$?
  for p in "${STREAM_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  if [ "$keep" = 1 ]; then
    echo "e2e: stack kept ($PROJECT); logs in $STATE/logs; remove with: DEV_STACK_KIND=e2e $STACK down -v"
  elif [ $rc -ne 0 ] && [ -d "$STATE/logs" ]; then
    mkdir -p "${TMPDIR:-/tmp}/orbitly-e2e-last" && cp -r "$STATE/logs/." "${TMPDIR:-/tmp}/orbitly-e2e-last/" 2>/dev/null || true
    echo "e2e: FAILED; server logs copied to ${TMPDIR:-/tmp}/orbitly-e2e-last" >&2
    "$STACK" down -v >/dev/null 2>&1 || true
  else
    "$STACK" down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "$keep" = 1 ] && [ -f "$STATE/stack.env" ] && curl -fsS --max-time 3 "$("$STACK" env | sed -n 's/^E2E_BASE_URL=//p')/healthz" >/dev/null 2>&1; then
  echo "== reusing the kept stack (restarting the API to reset its in-memory rate limits)"
  "$STACK" restart-api
else
  echo "== fresh stack"
  "$STACK" down -v >/dev/null 2>&1 || true
  "$STACK" up ${E2E_NO_BUILD:+--no-build}
fi

# Stream the container logs where the Dart tests can read them (the flutter container has no docker).
mkdir -p "$STATE/logs"
: >"$STATE/logs/api.log"; : >"$STATE/logs/postgres.log"
docker logs -f --tail 0 "$("$STACK" container api)" >>"$STATE/logs/api.log" 2>&1 & STREAM_PIDS+=($!)
docker logs -f --tail 0 "$("$STACK" container postgres)" >>"$STATE/logs/postgres.log" 2>&1 & STREAM_PIDS+=($!)

declare -A FILE=([auth]=auth_refresh_test.dart [lanes]=lanes_stack_test.dart [conn]=connections_test.dart)
fail=()
for w in "${want[@]}"; do
  echo "== scenario file: ${FILE[$w]}"
  if ! "$STACK" flutter "test/e2e_dev_stack/${FILE[$w]}" --reporter expanded; then fail+=("$w"); fi
done

# Audit of the server log, like scripts/e2e-lanes.sh: no plaintext coordinate of a phone-lane member, no chat words,
# no crash.
sleep 1
log="$STATE/logs/api.log"
# Cleo's phone-lane latitudes are 41.31415, 41.31435, 41.31455. Match them as a number (not inside a longer one, not
# in the "time=2026-..T05:50:41.3145Z" stamp every slog line starts with, which is dropped first).
coord_hits="$(sed -E 's/^time=[^ ]+ //' "$log" 2>/dev/null | grep -E '(^|[^0-9.])-?41\.314[0-9]{2}([^0-9]|$)' | head -3 || true)"
if [ -n "$coord_hits" ]; then echo "e2e: a phone-lane coordinate appears in the server log:" >&2; echo "$coord_hits" >&2; fail+=("log-coordinates"); fi
if grep -Ei 'panic|fatal error' "$log" >/dev/null 2>&1; then echo "e2e: the server log contains a panic" >&2; fail+=("log-panic"); fi
echo "e2e: server log has $(grep -c 'level=WARN' "$log" 2>/dev/null || true) WARN and $(grep -c 'level=ERROR' "$log" 2>/dev/null || true) ERROR lines"

if [ ${#fail[@]} -gt 0 ]; then echo "e2e: FAILED: ${fail[*]}" >&2; exit 1; fi
echo "e2e: all scenario files passed (${want[*]})"
