#!/usr/bin/env bash
# Verify that a backup actually restores: restore it into a THROWAWAY
# TimescaleDB container (never touches the live database), then check the
# schema and row counts.
#
# Usage: ./scripts/verify-backup.sh <backup.dump[.enc]> [--expect-counts FILE]
#        ./scripts/verify-backup.sh --from-s3 [latest|openfamily-<UTC timestamp>] [options]
#        ./scripts/verify-backup.sh --from-local [latest|openfamily-<UTC timestamp>] [options]
#   Prints "<table> <rows>" for every table in public. With --expect-counts the
#   output must equal FILE; with --source-container NAME it must equal the live
#   source's counts. Any difference fails.
# Env:   BACKUP_PASSPHRASE_FILE  for .enc backups (scripts/backup.sh format)
#        --from-s3 / --from-local verify a backup written by the `backup` compose service:
#        download, SHA-256 check against the manifest, age-decrypt (BACKUP_AGE_IDENTITY_FILE
#        or BACKUP_AGE_PASSPHRASE_FILE), then restore into the scratch container. See
#        scripts/lib-s3.sh for the S3 variables. Never touches the live database.
#        VERIFY_IGNORE_TABLES   space-separated tables left out of the --source-container /
#                               --expect-counts comparison (backup_runs changes while a
#                               backup is being recorded)
#        VERIFY_IMAGE            override the Postgres image (default: image pinned in docker-compose.yml)
# Exit:  0 verified, 1 verification failed, 2 usage.
set -euo pipefail
cd "$(dirname "$0")/.."

file="${1:-}"; expect=""
from=""; which="latest"
case "$file" in
  --from-s3|--from-local)
    from="${file#--from-}"; shift
    case "${1:-}" in ""|--*) ;; *) which="$1"; shift ;; esac
    file="" ;;
  *) [ -n "$file" ] && [ -f "$file" ] || { echo "usage: $0 <backup.dump[.enc]> | --from-s3|--from-local [latest|NAME]  [--expect-counts FILE | --source-container NAME]" >&2; exit 2; }
     shift ;;
esac
source_container=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-counts) expect="${2:?--expect-counts needs a file}"; shift 2 ;;
    --source-container) source_container="${2:?needs a container name}"; shift 2 ;; # compare with a live container (SOURCE_USER/SOURCE_DB)
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

image="${VERIFY_IMAGE:-$(sed -n 's/^ *image: *\(timescale\/timescaledb-ha:[^ ]*\).*/\1/p' docker-compose.yml | head -1)}"
[ -n "$image" ] || { echo "error: cannot determine the Postgres image" >&2; exit 2; }

work="$(mktemp -d)"; chmod 700 "$work"
name="openfamily-verify-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

src="$file"
if [ -n "$from" ]; then
  # shellcheck source=scripts/lib-s3.sh
  . "$(dirname "$0")/lib-s3.sh"
  fetch_backup "$from" "$which" "$work/b.dump" || { echo "FAIL: could not fetch a verified backup" >&2; exit 1; }
  src="$work/b.dump"; file="$from:$which"
fi
case "$file" in
  *.enc)
    [ -r "${BACKUP_PASSPHRASE_FILE:-}" ] || { echo "error: set BACKUP_PASSPHRASE_FILE" >&2; exit 2; }
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$BACKUP_PASSPHRASE_FILE" -in "$file" -out "$work/b.dump" \
      || { echo "FAIL: decryption failed" >&2; exit 1; }
    src="$work/b.dump" ;;
esac

docker run -d --name "$name" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=verify "$image" \
  -c fsync=off -c synchronous_commit=off >/dev/null
for _ in $(seq 1 90); do
  docker exec "$name" pg_isready -h 127.0.0.1 -U postgres -d verify >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$name" pg_isready -h 127.0.0.1 -U postgres -d verify >/dev/null 2>&1 || { echo "FAIL: scratch database did not start" >&2; exit 1; }

psql_() { docker exec -i "$name" psql -v ON_ERROR_STOP=1 -X -q -U postgres -d verify "$@"; }
psql_ -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" -c "SELECT timescaledb_pre_restore();" >/dev/null
docker exec -i "$name" pg_restore -U postgres -d verify --no-owner --exit-on-error <"$src" \
  || { echo "FAIL: pg_restore reported errors" >&2; exit 1; }
psql_ -c "SELECT timescaledb_post_restore();" >/dev/null

# Exact row counts for every ordinary table (hypertable chunks are counted via the parent).
counts_of() { # $1 container $2 user $3 db
  docker exec -i "$1" psql -v ON_ERROR_STOP=1 -X -At -U "$2" -d "$3" <<'SQL' | LC_ALL=C sort
SELECT format('%s %s', t.table_name,
  (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', t.table_schema, t.table_name), false, true, '')))[1]::text)
FROM information_schema.tables t
WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE';
SQL
}
filter_ignored() { # drop VERIFY_IGNORE_TABLES from "<table> <rows>" lines
  local out; out="$(cat)"
  for t in ${VERIFY_IGNORE_TABLES:-}; do out="$(printf '%s\n' "$out" | grep -v "^$t ")"; done
  printf '%s\n' "$out"
}
counts="$(counts_of "$name" postgres verify)"
if [ -z "$counts" ]; then echo "FAIL: restored database has no tables" >&2; exit 1; fi
echo "$counts"

if ! printf '%s\n' "$counts" | grep -q '^users '; then
  echo "FAIL: users table missing" >&2; exit 1
fi
if [ -n "$expect" ]; then
  if ! diff <(printf '%s\n' "$counts" | filter_ignored) <(LC_ALL=C sort "$expect" | filter_ignored); then
    echo "FAIL: row counts differ from $expect" >&2; exit 1
  fi
fi
if [ -n "$source_container" ]; then
  if ! diff <(printf '%s\n' "$counts" | filter_ignored) <(counts_of "$source_container" "${SOURCE_USER:-postgres}" "${SOURCE_DB:-verify}" | filter_ignored); then
    echo "FAIL: restored row counts differ from the source database" >&2; exit 1
  fi
fi
echo "VERIFIED: $file restored into a scratch database ($(printf '%s\n' "$counts" | wc -l) tables)"
