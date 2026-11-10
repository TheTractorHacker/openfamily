#!/usr/bin/env bash
# Put the server's own identity back from an encrypted backup made by scripts/backup.sh
# (openfamily-<time>.server-key.tar.enc). Use it after restoring the database onto a NEW machine or a
# lost volume, so every phone keeps trusting the same server key.
#
# Usage: BACKUP_PASSPHRASE_FILE=path ./scripts/restore-server-key.sh backups/<file>.server-key.tar.enc [--yes]
# DESTRUCTIVE for /data/server-device: an existing identity there is replaced.
set -euo pipefail

cd "$(dirname "$0")/.."

file="${1:-}"; yes="${2:-}"
[ -n "$file" ] && [ -f "$file" ] || { echo "usage: $0 <file>.server-key.tar.enc [--yes]" >&2; exit 2; }
[ -r "${BACKUP_PASSPHRASE_FILE:-}" ] || { echo "error: set BACKUP_PASSPHRASE_FILE to the passphrase file" >&2; exit 2; }
if [ "$yes" != "--yes" ]; then
  echo "This will REPLACE the server's key directory with the one in: $file"
  read -r -p "Type RESTORE to continue: " answer
  [ "$answer" = "RESTORE" ] || { echo "Aborted."; exit 1; }
fi
plain="$(mktemp)"; chmod 600 "$plain"
trap 'rm -f "$plain"' EXIT
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$BACKUP_PASSPHRASE_FILE" -in "$file" -out "$plain" \
  || { echo "error: decryption failed (wrong passphrase?)" >&2; exit 1; }
tar -tf "$plain" >/dev/null 2>&1 || { echo "error: the decrypted file is not an archive" >&2; exit 1; }
echo "Stopping api..."
docker compose stop api
# One-off container with the same volume and the same user as the API (uid 10001), never the host.
docker compose run --rm -T --no-deps --entrypoint sh api -c 'rm -rf /data/server-device/* && tar -C /data/server-device -xf - && chmod 700 /data/server-device' <"$plain"
docker compose up -d api
echo "Server key restored. Phones keep trusting the same server."
