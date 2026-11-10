#!/usr/bin/env bash
# A THROWAWAY Orbitly stack for development and end-to-end tests (docs/developers/dev-stack.md).
#
#   scripts/dev/dev-stack.sh up [--no-build]   build the API image from this tree (cached) and start the stack
#   scripts/dev/dev-stack.sh seed           owner + 2 family members + a Private circle with server processing on
#   scripts/dev/dev-stack.sh reset [--no-seed]   wipe the stack's volumes and secrets, start fresh, seed
#   scripts/dev/dev-stack.sh down [-v]      stop and remove the containers; -v also removes volumes and secrets
#   scripts/dev/dev-stack.sh status         ports, health, accounts
#
# Helpers used by scripts/dev/e2e.sh: env, container <service>, restart-api, psql <sql>, flutter <args>.
#
# What it is: the repo's own docker-compose.yml (same API Dockerfile, same pinned TimescaleDB image,
# same Postgres max_connections / API pool settings as production) layered with
# scripts/dev/dev-stack.compose.yml, under its OWN compose project name (default "orbitly-<kind>-<tag>"), its own
# volumes, its own free loopback ports and a freshly generated secrets file in a temp directory.
# It never reads the repo .env, never uses the production image tags (the API is tagged
# openfamily-api:devstack-<tag>), never starts the backup service, and refuses the production project name.
#
# Isolation is per WORKTREE: the compose project, the state directory and the image tag all carry a short hash
# of this checkout's path (TAG), so two worktrees (or a dev stack and an e2e run) never share containers, volumes,
# secrets or an image, and `down -v` in one can never remove another's. The same checkout cannot run two
# e2e.sh runs at once (a lock). `up` always runs `docker build` (layer-cached, seconds when nothing changed) so the
# stack serves THIS tree, not whatever image an earlier branch left behind; --no-build skips it on purpose.
#
# Environment: DEV_STACK_KIND (dev | e2e, part of the names, default dev), DEV_STACK_DIR (state + secrets, default
# $TMPDIR/orbitly-<kind>-<tag>-stack-<uid>; the last path component must match orbitly-*-stack-*),
# DEV_STACK_PROJECT, DEV_API_PORT / DEV_DB_PORT (default: random free ports), PG_MAX_CONNECTIONS (60),
# DB_MAX_CONNS (15), CPUS (flutter container, default 6), FLUTTER_IMAGE, GO_IMAGE.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="$(printf %s "$REPO" | sha256sum | cut -c1-8)"
KIND="${DEV_STACK_KIND:-dev}"
PROJECT="${DEV_STACK_PROJECT:-orbitly-$KIND-$TAG}"
STATE="${DEV_STACK_DIR:-${TMPDIR:-/tmp}/orbitly-$KIND-$TAG-stack-$(id -u)}"
ENVF="$STATE/stack.env"
OVERRIDE="$REPO/scripts/dev/dev-stack.compose.yml"
# One image per checkout; never the :local tag the production stack uses, never another worktree's.
IMAGE="${DEV_STACK_IMAGE:-openfamily-api:devstack-$TAG}"
FLUTTER_IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
GO_IMAGE="${GO_IMAGE:-golang:1.27}"
CPUS="${CPUS:-6}"
FLUTTER_CACHE_VOLUME="openfamily-flutter-cache"
GO_CACHE_VOLUME="openfamily-go-cache"

# Never operate on the production project, whatever the environment says: ours always start with "orbitly-".
case "$PROJECT" in
  orbitly-?*) ;;
  *) echo "dev-stack: refusing project name '$PROJECT' (must start with orbitly-, so it can never be the production stack)" >&2; exit 2 ;;
esac

die() { echo "dev-stack: $*" >&2; exit 1; }

# The state directory is cleaned by `down -v`: only a directory that is named like one of ours.
case "$(basename "$STATE")" in
  orbitly-*-stack-*) ;;
  *) echo "dev-stack: refusing DEV_STACK_DIR '$STATE': its last component must match orbitly-*-stack-*" >&2; exit 2 ;;
esac
case "$STATE" in /*) ;; *) echo "dev-stack: DEV_STACK_DIR must be an absolute path" >&2; exit 2 ;; esac
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

port_free() {
  ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$" \
    && ! docker ps --format '{{.Ports}}' | grep -Eq ":$1->"
}
pick_port() {
  local p
  for _ in $(seq 1 200); do
    p=$((18100 + RANDOM % 800))
    if port_free "$p"; then echo "$p"; return 0; fi
  done
  die "no free port found"
}

# Compose always runs in a clean environment: a stray POSTGRES_PASSWORD or JWT_SECRET exported in the
# caller's shell (a production .env sourced by hand, say) would beat --env-file and leak in.
compose() {
  env -i PATH="$PATH" HOME="$HOME" \
    ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
    ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} ${XDG_RUNTIME_DIR:+XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"} \
    docker compose --project-name "$PROJECT" --project-directory "$REPO" --env-file "$ENVF" \
    -f "$REPO/docker-compose.yml" -f "$OVERRIDE" "$@"
}

ensure_env() {
  mkdir -p "$STATE" "$STATE/bin" "$STATE/logs"
  chmod 700 "$STATE"
  [ -f "$ENVF" ] && return 0
  local api_port="${DEV_API_PORT:-$(pick_port)}" db_port="${DEV_DB_PORT:-}"
  [ -n "$db_port" ] || { db_port="$(pick_port)"; while [ "$db_port" = "$api_port" ]; do db_port="$(pick_port)"; done; }
  umask 077
  cat >"$ENVF" <<EOF
# Generated by scripts/dev/dev-stack.sh. Throwaway secrets for the $PROJECT stack only.
POSTGRES_USER=openfamily
POSTGRES_DB=openfamily
POSTGRES_PASSWORD=$(rand_hex 16)
JWT_SECRET=$(rand_hex 32)
PLATFORM_ADMIN_EMAIL=owner@dev.orbitly.test
PLATFORM_ADMIN_PASSWORD=Dev-$(rand_hex 9)
DEV_API_PORT=$api_port
DEV_DB_PORT=$db_port
API_BIND=127.0.0.1
PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS:-60}
DB_MAX_CONNS=${DB_MAX_CONNS:-15}
APP_ENV=development
TLS_BEHIND_PROXY=true
GEOCODER_URL=
GEOCODER_FALLBACK_URL=
GEOCODER_CENSUS_ENABLED=false
DIRECT_PUSH=false
BACKUP_REPLICAS=0
GIT_COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)
DEV_API_IMAGE=$IMAGE
EOF
}

getv() { grep -E "^$1=" "$ENVF" | head -1 | cut -d= -f2-; }
api_url() { echo "http://127.0.0.1:$(getv DEV_API_PORT)"; }
db_url() { echo "postgres://$(getv POSTGRES_USER):$(getv POSTGRES_PASSWORD)@127.0.0.1:$(getv DEV_DB_PORT)/$(getv POSTGRES_DB)?sslmode=disable"; }
container() { docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | head -1; }
healthy() { curl -fsS --max-time 3 "$(api_url)/healthz" >/dev/null 2>&1; }

wait_healthy() {
  for _ in $(seq 1 "${DEV_STACK_WAIT:-300}"); do healthy && return 0; sleep 1; done
  echo "dev-stack: the API did not become healthy; last log lines:" >&2
  compose logs --no-color --tail 40 api >&2 || true
  return 1
}

# Everything docker holds for this project, found by compose's own labels, so cleanup works even when the state
# file under /tmp is gone (reboot, tmp cleaner) while containers and volumes survive.
project_has() {
  [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ]
}
purge_project() {
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")"
  [ -z "$ids" ] || docker rm -f -v $ids >/dev/null 2>&1 || true
  ids="$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT")"
  [ -z "$ids" ] || docker network rm $ids >/dev/null 2>&1 || true
  if [ "${1:-}" = volumes ]; then
    ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
    [ -z "$ids" ] || docker volume rm -f $ids >/dev/null 2>&1 || true
  fi
}

cmd_up() {
  local build=1
  for a in "$@"; do [ "$a" = --no-build ] && build=0; done
  if [ ! -f "$ENVF" ] && project_has; then
    # Leftovers without their secrets: a new password would never match the old pgdata volume.
    echo "== stale containers/volumes of $PROJECT without a state file; removing them first"
    purge_project volumes
  fi
  ensure_env
  if [ "$build" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "== building $IMAGE from this tree (commit $(getv GIT_COMMIT)); layer-cached, the first build downloads the Go toolchain image and modules"
    compose build api
  fi
  echo "== starting project $PROJECT"
  compose up -d --no-build postgres
  local pg; pg="$(container postgres)"
  for _ in $(seq 1 "${DEV_STACK_WAIT:-300}"); do
    # Over TCP: while the image initialises the database it runs a temporary server on the unix socket only
    # (and the database does not exist yet); only the final server listens on TCP.
    docker exec "$pg" psql -h 127.0.0.1 -U "$(getv POSTGRES_USER)" -d "$(getv POSTGRES_DB)" -qAtc 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  # A throwaway database: speed, not durability. These settings reload without a restart, so the container
  # keeps docker-compose.yml's own `command` (the production max_connections) untouched.
  for kv in fsync=off synchronous_commit=off full_page_writes=off; do
    docker exec "$pg" psql -U "$(getv POSTGRES_USER)" -d "$(getv POSTGRES_DB)" -qAtc "ALTER SYSTEM SET ${kv%%=*} = '${kv#*=}'" >/dev/null
  done
  docker exec "$pg" psql -U "$(getv POSTGRES_USER)" -d "$(getv POSTGRES_DB)" -qAtc "SELECT pg_reload_conf()" >/dev/null
  compose up -d --no-build api
  wait_healthy
  echo "dev-stack: up. API $(api_url)  database 127.0.0.1:$(getv DEV_DB_PORT)  state $STATE"
}

cmd_down() {
  if [ -f "$ENVF" ]; then
    if [ "${1:-}" = -v ]; then compose down -v --remove-orphans || true; else compose down --remove-orphans || true; fi
  fi
  if [ "${1:-}" = -v ]; then
    purge_project volumes
    # Only what this script created, never a recursive delete of whatever DEV_STACK_DIR points at.
    rm -rf "${STATE:?}/bin" "${STATE:?}/logs"
    rm -f "${STATE:?}/stack.env" "${STATE:?}/seed.json"
    rmdir "${STATE:?}" 2>/dev/null || true
    echo "dev-stack: removed containers, volumes and the secrets in $STATE"
  else
    purge_project
    echo "dev-stack: containers removed; volumes and secrets kept in $STATE (down -v removes them)"
  fi
}

fix_owner() { docker run --rm -v "$REPO":/r alpine chown -R "$(id -u):$(id -g)" /r/app/.dart_tool /r/app/build /r/backend 2>/dev/null || true; }

# The SQL probe (scripts/e2e-lanes/probe.go, a static binary) is built once and cached outside the state
# directory, keyed on its source and the module lock, so every fresh stack reuses it.
PROBE_CACHE="${DEV_STACK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/orbitly-dev-stack}"
build_probe() {
  local key; key="$(cat "$REPO/scripts/e2e-lanes/probe.go" "$REPO/backend/go.sum" | sha256sum | cut -c1-16)"
  local bin="$PROBE_CACHE/e2eprobe-$key"
  mkdir -p "$PROBE_CACHE" "$STATE/bin"
  if [ ! -x "$bin" ]; then
    echo "== building the SQL probe"
    mkdir -p "$REPO/backend/cmd/_e2eprobe"
    cp "$REPO/scripts/e2e-lanes/probe.go" "$REPO/backend/cmd/_e2eprobe/main.go"
    docker run --rm -v "$REPO/backend":/src -v "$PROBE_CACHE":/out -v "$GO_CACHE_VOLUME":/go -w /src \
      -e CGO_ENABLED=0 "$GO_IMAGE" sh -c "go build -trimpath -o /out/e2eprobe-$key ./cmd/_e2eprobe" \
      || { rm -rf "$REPO/backend/cmd/_e2eprobe"; die "probe build failed"; }
    rm -rf "$REPO/backend/cmd/_e2eprobe"
    fix_owner
  fi
  cp "$bin" "$STATE/bin/e2eprobe"
}

# The command docker-compose.yml gives the postgres service, as compose renders it for this stack. Scenario (e)
# reads the expected max_connections from it, independent of PG_MAX_CONNECTIONS in stack.env.
pg_compose_command() { compose config --format json | jq -r '.services.postgres.command // [] | join(" ")'; }

# Runs `flutter test` in the flutter image on the host network, pointed at this stack.
# Extra docker args come from FLUTTER_DOCKER_ARGS (a bash array exported as a string is not possible,
# so callers set E2E_EXTRA_ENV="-e A=b -e C=d").
cmd_flutter() {
  build_probe
  local rc=0
  # shellcheck disable=SC2086
  docker run --rm --cpus="$CPUS" --network host \
    -v "$REPO":/work -v "$FLUTTER_CACHE_VOLUME":/root/.pub-cache -v "$STATE":/state -w /work/app \
    -e E2E_DEV_STACK=1 -e E2E_BASE_URL="$(api_url)" -e E2E_DATABASE_URL="$(db_url)" \
    -e E2E_PROBE_BIN=/state/bin/e2eprobe -e E2E_STATE_DIR=/state \
    -e E2E_OWNER_EMAIL="$(getv PLATFORM_ADMIN_EMAIL)" -e E2E_OWNER_PASSWORD="$(getv PLATFORM_ADMIN_PASSWORD)" \
    -e E2E_PG_COMPOSE_COMMAND="$(pg_compose_command)" -e E2E_DB_MAX_CONNS="$(getv DB_MAX_CONNS)" \
    ${E2E_EXTRA_ENV:-} \
    "$FLUTTER_IMAGE" sh -c 'git config --global --add safe.directory "*" >/dev/null 2>&1; flutter pub get >/dev/null 2>&1 && flutter test "$@"' sh "$@" || rc=$?
  fix_owner
  return $rc
}

cmd_seed() {
  healthy || die "the stack is not up (scripts/dev/dev-stack.sh up)"
  rm -f "$STATE/seed.json"
  echo "== seeding through the real API with the app's own crypto client"
  cmd_flutter test/e2e_dev_stack/seed_test.dart --reporter expanded
  [ -s "$STATE/seed.json" ] || die "seeding did not write $STATE/seed.json"
  echo "dev-stack: seeded. Accounts and circle: $STATE/seed.json"
  jq -r '"  owner  \(.owner.email)  (password in stack.env: PLATFORM_ADMIN_PASSWORD)\n  member \(.members[0].email)\n  member \(.members[1].email)\n  circle \(.circle_id)  (Private, server processing on)"' "$STATE/seed.json"
}

cmd_reset() {
  local seed=1
  [ "${1:-}" = --no-seed ] && seed=0
  cmd_down -v
  cmd_up
  [ "$seed" = 1 ] && cmd_seed
  return 0
}

cmd_status() {
  if [ ! -f "$ENVF" ]; then echo "dev-stack: not created (no $ENVF)"; return 0; fi
  echo "project   $PROJECT"
  echo "state     $STATE"
  echo "API       $(api_url)  $(healthy && echo healthy || echo 'NOT answering')"
  echo "database  127.0.0.1:$(getv DEV_DB_PORT)  max_connections=$(getv PG_MAX_CONNECTIONS) pool=$(getv DB_MAX_CONNS)"
  echo "image     $IMAGE  $(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null | cut -c8-19)  built $(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null | cut -c1-19)  commit label $(docker image inspect -f '{{index .Config.Labels "org.orbitly.devstack.commit"}}' "$IMAGE" 2>/dev/null)  (this tree: $(getv GIT_COMMIT))"
  compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null || true
  if [ -s "$STATE/seed.json" ]; then
    echo "seeded    yes"
    jq -r '"owner     \(.owner.email)\nmembers   \(.members[0].email), \(.members[1].email)\ncircle    \(.circle_id)"' "$STATE/seed.json"
  else
    echo "seeded    no"
  fi
}

cmd="${1:-}"; [ $# -ge 1 ] && shift
case "$cmd" in
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  reset) cmd_reset "$@" ;;
  seed) ensure_env; cmd_seed ;;
  status) cmd_status ;;
  # helpers
  state-dir) echo "$STATE" ;;
  project) echo "$PROJECT" ;;
  env) ensure_env; echo "E2E_BASE_URL=$(api_url)"; echo "E2E_DATABASE_URL=$(db_url)"; echo "STATE=$STATE" ;;
  container) ensure_env; container "${1:?service}" ;;
  restart-api) ensure_env; docker restart "$(container api)" >/dev/null; wait_healthy ;;
  psql) ensure_env; docker exec "$(container postgres)" psql -U "$(getv POSTGRES_USER)" -d "$(getv POSTGRES_DB)" -tAc "${1:?sql}" ;;
  flutter) ensure_env; cmd_flutter "$@" ;;
  logs) ensure_env; compose logs --no-color "$@" ;;
  *) sed -n '2,32p' "$0"; exit 2 ;;
esac
