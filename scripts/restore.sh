#!/usr/bin/env bash
# Restore the Orbitly database from a backup made by scripts/backup.sh.
# DESTRUCTIVE: the current database is dropped and recreated.
#
# Usage: ./scripts/restore.sh backups/openfamily-<timestamp>.dump[.enc] [--yes]
#        ./scripts/restore.sh --from-s3 [latest|openfamily-<UTC timestamp>] [--yes]
#        ./scripts/restore.sh --from-local [latest|openfamily-<UTC timestamp>] [--yes]
# Env:   BACKUP_PASSPHRASE_FILE=path  required for .enc backups (scripts/backup.sh format)
#        --from-s3 / --from-local read backups written by the `backup` compose service:
#        the download is verified against its SHA-256 manifest, then decrypted with
#        BACKUP_AGE_IDENTITY_FILE=path (age private key) or BACKUP_AGE_PASSPHRASE_FILE.
#        S3 settings (BACKUP_S3_*) are read from the environment or ./.env.
set -euo pipefail

cd "$(dirname "$0")/.."

file="${1:-}"
yes="${2:-}"
case "$file" in
  --from-s3|--from-local)
    # shellcheck source=scripts/lib-s3.sh
    . "$(dirname "$0")/lib-s3.sh"
    which="latest"
    case "${2:-}" in ""|--yes) ;; *) which="$2"; yes="${3:-}" ;; esac
    [ "${2:-}" = "--yes" ] && yes="--yes"
    fetched="$(mktemp -d)"; chmod 700 "$fetched"
    trap 'rm -rf "$fetched"' EXIT
    fetch_backup "${file#--from-}" "$which" "$fetched/restore.dump" || { echo "error: could not fetch a verified backup" >&2; exit 1; }
    echo "Downloaded, checksum-verified and decrypted: $which (${file#--from-})"
    file="$fetched/restore.dump" ;;
esac
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "usage: $0 <backup.dump> [--yes] | --from-s3|--from-local [latest|NAME] [--yes]" >&2
  exit 2
fi

case "$file" in
  *.enc)
    [ -r "${BACKUP_PASSPHRASE_FILE:-}" ] || { echo "error: set BACKUP_PASSPHRASE_FILE to restore an encrypted backup" >&2; exit 2; }
    plain="$(mktemp)"; chmod 600 "$plain"
    trap 'rm -f "$plain"' EXIT
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$BACKUP_PASSPHRASE_FILE" -in "$file" -out "$plain" \
      || { echo "error: decryption failed (wrong passphrase?)" >&2; exit 1; }
    src="$plain" ;;
  *) src="$file" ;;
esac

if [ "$yes" != "--yes" ]; then
  echo "This will REPLACE the current Orbitly database with: $file"
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
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' <"$src" || rc=$?
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
