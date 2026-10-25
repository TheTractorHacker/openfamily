#!/usr/bin/env bash
# Restore the OpenFamily database from a backup made by scripts/backup.sh.
# DESTRUCTIVE: the current database is dropped and recreated.
#
# Usage: ./scripts/restore.sh backups/openfamily-<timestamp>.dump [--yes]
set -euo pipefail

cd "$(dirname "$0")/.."

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "usage: $0 <backup.dump> [--yes]" >&2
  exit 2
fi

if [ "${2:-}" != "--yes" ]; then
  echo "This will REPLACE the current OpenFamily database with: $file"
  read -r -p "Type RESTORE to continue: " answer
  [ "$answer" = "RESTORE" ] || { echo "Aborted."; exit 1; }
fi

if ! docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  echo "error: the postgres service is not running (docker compose up -d postgres)" >&2
  exit 1
fi

echo "Stopping api..."
docker compose stop api

# Runs inside the postgres container; $POSTGRES_* come from its environment.
# TimescaleDB requires pre/post restore calls around pg_restore.
docker compose exec -T postgres sh -ec '
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '"'"'$POSTGRES_DB'"'"' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$POSTGRES_DB";
CREATE DATABASE "$POSTGRES_DB" OWNER "$POSTGRES_USER";
SQL
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" -c "SELECT timescaledb_pre_restore();"
'
# pg_restore may report benign warnings (e.g. extension already exists); the
# explicit post_restore below still runs, and the exit status is shown.
rc=0
docker compose exec -T postgres sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' <"$file" || rc=$?
docker compose exec -T postgres sh -c \
  'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT timescaledb_post_restore();"'

if [ "$rc" -ne 0 ]; then
  echo "error: pg_restore exited with status $rc; the api was left stopped." >&2
  echo "Inspect the database, then retry or restore an older backup." >&2
  exit "$rc"
fi

echo "Starting api..."
docker compose up -d api
echo "Restore complete."
