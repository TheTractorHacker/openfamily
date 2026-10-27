#!/usr/bin/env bash
# Upgrade a self-hosted OpenFamily install in place.
#
#   1. refuses to run with uncommitted changes
#   2. backs up the database to ./backups
#   3. git pull --ff-only, rebuilds and restarts via docker compose
#   4. waits for the API /healthz
#   5. on failure, rolls the code back to the previous git ref and tells you
#      how to restore the backup if the database needs it
#
# Usage: ./scripts/upgrade.sh [git-ref]   (default: fast-forward the current branch)
# Env:   HEALTH_TIMEOUT=seconds to wait for /healthz (default 120)
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "error: uncommitted changes in the working tree; commit or stash them first." >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

prev_ref="$(git rev-parse HEAD)"
prev_branch="$(git symbolic-ref --quiet --short HEAD || true)"

echo "==> Backing up the database"
backup="backups/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).dump"
./scripts/backup.sh "$backup"

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker compose exec -T api sh -c 'wget -qO- "http://127.0.0.1${HTTP_ADDR:-:8080}/healthz" >/dev/null' 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

rollback() {
  echo "==> Upgrade failed; rolling back code to $prev_ref" >&2
  if [ -n "$prev_branch" ]; then
    git checkout --quiet "$prev_branch"
    git reset --hard --quiet "$prev_ref"
  else
    git checkout --quiet "$prev_ref"
  fi
  GIT_COMMIT="$(git describe --tags --always)" docker compose up -d --build || true
  echo >&2
  echo "Code is back at $prev_ref. If the new version already migrated the database," >&2
  echo "the old code may not work against it. Restore the pre-upgrade backup with:" >&2
  echo "  ./scripts/restore.sh $backup" >&2
  exit 1
}

echo "==> Fetching updates"
if ! {
  git fetch --quiet --tags origin
  if [ -n "$TARGET" ]; then
    git checkout --quiet "$TARGET"
  else
    git pull --ff-only --quiet
  fi
}; then
  echo "error: could not update the source; nothing was changed." >&2
  git checkout --quiet "${prev_branch:-$prev_ref}" 2>/dev/null || true
  exit 1
fi

new_ref="$(git rev-parse HEAD)"
if [ "$new_ref" = "$prev_ref" ]; then
  echo "Already up to date ($(git rev-parse --short HEAD)); rebuilding anyway."
fi

echo "==> Rebuilding and restarting"
GIT_COMMIT="$(git describe --tags --always)" docker compose up -d --build --remove-orphans || rollback

echo "==> Waiting for /healthz (up to ${HEALTH_TIMEOUT}s)"
wait_healthy || rollback

echo "Upgrade complete: $(git rev-parse --short "$prev_ref") -> $(git rev-parse --short HEAD)"
echo "Pre-upgrade backup kept at $backup"
