#!/usr/bin/env bash
# Back up the OpenFamily database to ./backups/openfamily-<timestamp>.dump
# (pg_dump custom format, restorable with scripts/restore.sh).
#
# Usage: ./scripts/backup.sh [output-file]
# Env:   BACKUP_KEEP=N  keep only the newest N automatic backups (default: keep all)
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p backups
chmod 700 backups
out="${1:-backups/openfamily-$(date -u +%Y%m%dT%H%M%SZ).dump}"

if ! docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  echo "error: the postgres service is not running (docker compose up -d postgres)" >&2
  exit 1
fi

umask 077
tmp="${out}.partial"
trap 'rm -f "$tmp"' EXIT

# Credentials come from the container's own environment; nothing is passed on
# the command line.
docker compose exec -T postgres sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner' >"$tmp"

if [ ! -s "$tmp" ]; then
  echo "error: backup is empty" >&2
  exit 1
fi
mv "$tmp" "$out"
trap - EXIT
echo "Backup written: $out ($(du -h "$out" | cut -f1))"

if [ -n "${BACKUP_KEEP:-}" ] && [ -z "${1:-}" ]; then
  # shellcheck disable=SC2012
  ls -1t backups/openfamily-*.dump 2>/dev/null | tail -n "+$((BACKUP_KEEP + 1))" | xargs -r rm -f --
fi
