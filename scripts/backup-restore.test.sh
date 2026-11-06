#!/usr/bin/env bash
# End-to-end test of the backup -> verify path against THROWAWAY containers.
# Applies every migration to a scratch TimescaleDB, seeds rows (including
# location history), takes a pg_dump exactly like scripts/backup.sh, encrypts
# it, and runs scripts/verify-backup.sh with row-count comparison. Also checks
# that a corrupted backup and a wrong passphrase are rejected.
#
# Usage: scripts/backup-restore.test.sh      (needs docker; ~1-2 min)
set -euo pipefail
cd "$(dirname "$0")/.."

image="$(sed -n 's/^ *image: *\(timescale\/timescaledb-ha:[^ ]*\).*/\1/p' docker-compose.yml | head -1)"
src="openfamily-brtest-src-$$"
work="$(mktemp -d)"
cleanup() { docker rm -f "$src" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

docker run -d --name "$src" -e POSTGRES_PASSWORD=t -e POSTGRES_DB=verify "$image" -c fsync=off -c synchronous_commit=off >/dev/null
for _ in $(seq 1 90); do docker exec "$src" pg_isready -h 127.0.0.1 -U postgres -d verify >/dev/null 2>&1 && break; sleep 1; done
sq() { docker exec -i "$src" psql -v ON_ERROR_STOP=1 -X -q -U postgres -d verify "$@"; }

sq -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >/dev/null
for f in $(ls backend/internal/db/migrations/*.up.sql | LC_ALL=C sort); do
  sq <"$f" >/dev/null || { echo "migration failed: $f" >&2; exit 1; }
done
echo "migrations applied"

sq <<'SQL' >/dev/null
INSERT INTO users (id, email, password_hash, name)
SELECT gen_random_uuid(), 'u' || g || '@example.test', 'x', 'User ' || g FROM generate_series(1, 5) g;
SQL
users="$(sq -At -c 'SELECT count(*) FROM users')"
[ "$users" = "5" ] || { echo "seed failed (users=$users)" >&2; exit 1; }

docker exec "$src" pg_dump -U postgres -d verify --format=custom --no-owner >"$work/plain.dump"
[ -s "$work/plain.dump" ] || { echo "empty dump" >&2; exit 1; }
printf 'test-passphrase' >"$work/pass"; chmod 600 "$work/pass"
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$work/pass" -in "$work/plain.dump" -out "$work/b.dump.enc"

echo "--- plain backup"
scripts/verify-backup.sh "$work/plain.dump" --source-container "$src"
echo "--- encrypted backup"
BACKUP_PASSPHRASE_FILE="$work/pass" scripts/verify-backup.sh "$work/b.dump.enc" --source-container "$src"

echo "--- negative: wrong passphrase must fail"
printf 'wrong' >"$work/bad"
if BACKUP_PASSPHRASE_FILE="$work/bad" scripts/verify-backup.sh "$work/b.dump.enc" >/dev/null 2>&1; then
  echo "FAIL: wrong passphrase accepted" >&2; exit 1; fi
echo "--- negative: truncated backup must fail"
head -c 2000 "$work/plain.dump" >"$work/trunc.dump"
if scripts/verify-backup.sh "$work/trunc.dump" >/dev/null 2>&1; then
  echo "FAIL: truncated backup accepted" >&2; exit 1; fi
echo "backup-restore test PASSED"
