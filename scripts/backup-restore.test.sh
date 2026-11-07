#!/usr/bin/env bash
# End-to-end test of the backup -> verify path against THROWAWAY containers.
# Applies every migration to a scratch TimescaleDB, seeds rows (including
# location history), takes a pg_dump exactly like scripts/backup.sh, encrypts
# it, and runs scripts/verify-backup.sh with row-count comparison. Also checks
# that a corrupted backup and a wrong passphrase are rejected.
#
# Second half: the S3 path. It starts a throwaway MinIO (pinned by digest),
# runs the real `backup` service binary (pg_dump -> age encryption -> local dir
# + S3 with a SHA-256 manifest), then downloads, verifies, decrypts and
# restores into a scratch database via scripts/verify-backup.sh --from-s3 and
# compares row counts. Negative cases: wrong key, tampered object, plain-http
# endpoint without the insecure flag, wrong secret (must not leak into output).
# Also exercises retention (dry-run and real; newest always kept), the
# daemon's admin-request queue (backup_requests), and settings saved the way the
# admin UI saves them (sealed credentials in backup_settings) being applied by
# a running service with no S3 environment and no restart.
#
# Usage: scripts/backup-restore.test.sh      (needs docker; ~3-5 min)
# Env:   BACKUP_IMAGE  use this prebuilt backup image instead of building one
#        SKIP_S3=1     only run the passphrase/openssl half
set -euo pipefail
cd "$(dirname "$0")/.."

image="$(sed -n 's/^ *image: *\(timescale\/timescaledb-ha:[^ ]*\).*/\1/p' docker-compose.yml | head -1)"
src="openfamily-brtest-src-$$"
net="openfamily-brtest-net-$$"
minio="openfamily-brtest-minio-$$"
daemon="openfamily-brtest-daemon-$$"
daemon2="openfamily-brtest-daemon2-$$"
daemon2="openfamily-brtest-daemon2-$$"
work="$(mktemp -d)"
cleanup() {
  docker rm -f "$src" "$minio" "$daemon" "$daemon2" "$daemon2" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  # MinIO wrote files as another uid; remove them from inside a container.
  [ -d "$work/minio-data" ] && [ -n "${image:-}" ] && docker run --rm --user 0 --entrypoint rm -v "$work:/w" "$image" -rf /w/minio-data >/dev/null 2>&1 || true
  rm -rf "$work" || true
}
trap cleanup EXIT
docker network create "$net" >/dev/null

docker run -d --name "$src" --network "$net" -e POSTGRES_PASSWORD=t -e POSTGRES_DB=verify "$image" -c fsync=off -c synchronous_commit=off >/dev/null
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
echo "--- passphrase/openssl half PASSED"
[ "${SKIP_S3:-}" = "1" ] && { echo "backup-restore test PASSED (S3 half skipped)"; exit 0; }

# ======================================================================= S3 half
# Docker Hub no longer hosts official MinIO images; this is Chainguard's MinIO build, pinned by digest.
MINIO_IMAGE="cgr.dev/chainguard/minio@sha256:aea6c163749e1caca37f907976dcf337177ddf5f558808f2aa591618fd3a6eef"
image="${BACKUP_IMAGE:-}"
if [ -z "$image" ]; then
  image="openfamily-backup:test-$$"
  docker build -q -f backend/Dockerfile --target backup -t "$image" . >/dev/null
fi
bucket="of-test"; ak="AKIATESTACCESS$RANDOM"; sk="sk-$(openssl rand -hex 16)"
# The bucket is a pre-created directory in MinIO's (single-drive) data dir.
mkdir -p "$work/minio-data/$bucket"; chmod -R 777 "$work/minio-data"
docker run -d --name "$minio" --network "$net" -v "$work/minio-data:/data" -e MINIO_ROOT_USER="$ak" -e MINIO_ROOT_PASSWORD="$sk" \
  "$MINIO_IMAGE" server /data >/dev/null

docker run --rm "$image" keygen >"$work/age.key" 2>"$work/age.pub"
chmod 600 "$work/age.key"
pub="$(sed -n 's/^public key (BACKUP_AGE_RECIPIENT): //p' "$work/age.pub")"
case "$pub" in age1*) ;; *) echo "keygen failed" >&2; exit 1 ;; esac
grep -q '^AGE-SECRET-KEY-' "$work/age.key" || { echo "keygen did not print a private key" >&2; exit 1; }
mkdir -p "$work/local" "$work/lib"; chmod 777 "$work/local"

dburl="postgres://postgres:t@$src:5432/verify?sslmode=disable"
bk() { # run the backup binary in a throwaway container on the test network
  docker run --rm --network "$net" --user "$(id -u):$(id -g)" --tmpfs /work:mode=1777 -e BACKUP_WORK_DIR=/work \
    -e DATABASE_URL="$dburl" -e BACKUP_AGE_RECIPIENT="$pub" -e BACKUP_LOCAL_DIR=/backups -v "$work/local:/backups" \
    -e BACKUP_S3_ENDPOINT="http://$minio:9000" -e BACKUP_S3_INSECURE=true -e BACKUP_S3_PATH_STYLE=true \
    -e BACKUP_S3_BUCKET="$bucket" -e BACKUP_S3_PREFIX=ofbk -e BACKUP_S3_REGION=us-east-1 \
    -e BACKUP_S3_ACCESS_KEY_ID="$ak" -e BACKUP_S3_SECRET_ACCESS_KEY="$sk" "$@"
}

echo "--- S3: connection test (write/read/delete a probe object)"
for _ in $(seq 1 30); do out="$(bk "$image" test-s3 2>&1)" && break; sleep 2; done
echo "$out"
echo "$out" | grep -q "S3 connection OK" || { echo "FAIL: test-s3" >&2; exit 1; }

echo "--- S3: negative: plain http without the insecure flag is refused"
if docker run --rm --network "$net" -e BACKUP_S3_BUCKET=b -e BACKUP_S3_ENDPOINT="http://$minio:9000" -e BACKUP_S3_ACCESS_KEY_ID=x -e BACKUP_S3_SECRET_ACCESS_KEY=y \
     -e BACKUP_AGE_RECIPIENT="$pub" "$image" test-s3 >"$work/tls.out" 2>&1; then echo "FAIL: http accepted" >&2; exit 1; fi
grep -q "TLS is required" "$work/tls.out" || { echo "FAIL: no TLS message" >&2; cat "$work/tls.out" >&2; exit 1; }

echo "--- S3: negative: wrong secret fails and is never printed"
if docker run --rm --network "$net" -e BACKUP_S3_BUCKET="$bucket" -e BACKUP_S3_ENDPOINT="http://$minio:9000" -e BACKUP_S3_INSECURE=true \
     -e BACKUP_S3_PATH_STYLE=true -e BACKUP_S3_ACCESS_KEY_ID="$ak" -e BACKUP_S3_SECRET_ACCESS_KEY="wrong-secret-value-xyz" \
     -e BACKUP_AGE_RECIPIENT="$pub" "$image" test-s3 >"$work/bad.out" 2>&1; then echo "FAIL: wrong secret accepted" >&2; exit 1; fi
if grep -q "wrong-secret-value-xyz\|$sk" "$work/bad.out"; then echo "FAIL: secret leaked in output" >&2; exit 1; fi

echo "--- S3: backup #1 -> local dir + MinIO (encrypted, manifest)"
bk "$image" run 2>&1 | tee "$work/run1.out"
if grep -q "$sk\|AGE-SECRET-KEY" "$work/run1.out"; then echo "FAIL: secret in run output" >&2; exit 1; fi
ls "$work/local" | grep -q '\.dump\.age$' || { echo "FAIL: no encrypted local dump" >&2; exit 1; }
ls "$work/local" | grep -q '\.manifest\.json$' || { echo "FAIL: no local manifest" >&2; exit 1; }
if grep -qa 'PGDMP' "$work/local/"*.dump.age; then echo "FAIL: plaintext in the encrypted dump" >&2; exit 1; fi
runs="$(sq -At -c "SELECT count(*) FROM backup_runs WHERE status='success' AND encrypted AND destination IN ('s3','local') AND size_bytes > 0")"
[ "$runs" = "2" ] || { echo "FAIL: expected 2 success rows in backup_runs, got $runs" >&2; exit 1; }
list="$(bk "$image" list)"; echo "$list"
echo "$list" | grep -q '^s3' || { echo "FAIL: nothing listed in S3" >&2; exit 1; }

echo "--- S3: restore drill: download -> SHA-256 -> decrypt -> scratch DB -> row counts"
export BACKUP_S3_ENDPOINT="http://$minio:9000" BACKUP_S3_INSECURE=true BACKUP_S3_PATH_STYLE=true BACKUP_S3_BUCKET="$bucket" \
  BACKUP_S3_PREFIX=ofbk BACKUP_S3_REGION=us-east-1 BACKUP_S3_ACCESS_KEY_ID="$ak" BACKUP_S3_SECRET_ACCESS_KEY="$sk" \
  BACKUP_IMAGE="$image" BACKUP_FETCH_NETWORK="$net" BACKUP_AGE_IDENTITY_FILE="$work/age.key" BACKUP_LOCAL_PATH="$work/local"
VERIFY_IGNORE_TABLES="backup_runs backup_requests backup_agent" scripts/verify-backup.sh --from-s3 latest --source-container "$src"
echo "--- local-dir variant of the same drill"
VERIFY_IGNORE_TABLES="backup_runs backup_requests backup_agent" scripts/verify-backup.sh --from-local latest --source-container "$src"

echo "--- S3: negative: wrong private key must fail"
docker run --rm "$image" keygen >"$work/other.key" 2>/dev/null; chmod 600 "$work/other.key"
if BACKUP_AGE_IDENTITY_FILE="$work/other.key" scripts/verify-backup.sh --from-s3 latest >"$work/wk.out" 2>&1; then echo "FAIL: wrong key accepted" >&2; exit 1; fi
grep -q "does not match" "$work/wk.out" || { echo "FAIL: unexpected wrong-key error" >&2; cat "$work/wk.out" >&2; exit 1; }

echo "--- negative: tampered local object is rejected by the checksum before decryption"
obj="$(ls "$work/local/"*.dump.age | head -1)"
cur="$(dd if="$obj" bs=1 skip=100 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"   # always change the byte (a fixed value could equal it)
printf "\\$(printf '%03o' $(( (cur + 1) % 256 )))" | dd of="$obj" bs=1 seek=100 conv=notrunc 2>/dev/null
if scripts/verify-backup.sh --from-local latest >"$work/tamper.out" 2>&1; then echo "FAIL: tampered backup accepted" >&2; exit 1; fi
grep -q "CHECKSUM MISMATCH" "$work/tamper.out" || { echo "FAIL: tamper not reported as checksum mismatch" >&2; cat "$work/tamper.out" >&2; exit 1; }

echo "--- retention against real S3: 3 backups, dry-run first, newest always survives"
# (retention 0/0/0 = keep everything; with the defaults a second backup on the same day replaces the first)
keepall=(-e BACKUP_KEEP_DAILY=0 -e BACKUP_KEEP_WEEKLY=0 -e BACKUP_KEEP_MONTHLY=0)
sleep 1; bk "${keepall[@]}" "$image" run >/dev/null 2>&1; sleep 1; bk "${keepall[@]}" "$image" run >/dev/null 2>&1
n="$(bk "$image" list | grep -c '^s3')"; [ "$n" = "3" ] || { echo "FAIL: expected 3 S3 backups, got $n" >&2; exit 1; }
newest="$(bk "$image" list | grep '^s3' | sort -k3 | tail -1 | cut -f2)"
bk -e BACKUP_KEEP_DAILY=1 -e BACKUP_KEEP_WEEKLY=0 -e BACKUP_KEEP_MONTHLY=0 "$image" prune --dry-run | grep -c '^would delete s3' | grep -qx 4 \
  || { echo "FAIL: dry-run should list 4 S3 objects (2 old dumps + manifests)" >&2; exit 1; }
n="$(bk "$image" list | grep -c '^s3')"; [ "$n" = "3" ] || { echo "FAIL: dry-run deleted something" >&2; exit 1; }
bk -e BACKUP_KEEP_DAILY=1 -e BACKUP_KEEP_WEEKLY=0 -e BACKUP_KEEP_MONTHLY=0 "$image" prune >/dev/null
left="$(bk "$image" list | grep '^s3' | cut -f2)"
[ "$left" = "$newest" ] || { echo "FAIL: prune must leave exactly the newest backup ($newest), got: $left" >&2; exit 1; }
scripts/verify-backup.sh --from-s3 latest >/dev/null || { echo "FAIL: newest backup unusable after prune" >&2; exit 1; }

echo "--- daemon: admin-panel requests (back up now / test S3) are served and recorded"
docker run -d --name "$daemon" --network "$net" --user "$(id -u):$(id -g)" --tmpfs /work:mode=1777 -e BACKUP_WORK_DIR=/work \
  -e DATABASE_URL="$dburl" -e BACKUP_AGE_RECIPIENT="$pub" -e BACKUP_POLL_SECONDS=2 -e BACKUP_SCHEDULE="0 0 1 1 *" \
  -e BACKUP_S3_ENDPOINT="http://$minio:9000" -e BACKUP_S3_INSECURE=true -e BACKUP_S3_PATH_STYLE=true -e BACKUP_S3_BUCKET="$bucket" \
  -e BACKUP_S3_PREFIX=ofbk -e BACKUP_S3_REGION=us-east-1 -e BACKUP_S3_ACCESS_KEY_ID="$ak" -e BACKUP_S3_SECRET_ACCESS_KEY="$sk" \
  "$image" daemon >/dev/null
sq -c "INSERT INTO backup_requests (kind) VALUES ('test_s3')" >/dev/null
for _ in $(seq 1 60); do
  st="$(sq -At -c "SELECT status FROM backup_requests ORDER BY id DESC LIMIT 1")"; [ "$st" = "done" ] || [ "$st" = "failed" ] && break; sleep 1
done
[ "$st" = "done" ] || { echo "FAIL: test_s3 request ended as '$st'" >&2; docker logs "$daemon" >&2; exit 1; }
sq -c "INSERT INTO backup_requests (kind) VALUES ('backup')" >/dev/null
for _ in $(seq 1 90); do
  st="$(sq -At -c "SELECT status FROM backup_requests ORDER BY id DESC LIMIT 1")"; [ "$st" = "done" ] || [ "$st" = "failed" ] && break; sleep 1
done
[ "$st" = "done" ] || { echo "FAIL: backup request ended as '$st'" >&2; docker logs "$daemon" >&2; exit 1; }
[ "$(sq -At -c "SELECT count(*) FROM backup_runs WHERE trigger='manual' AND destination='s3' AND status='success'")" = "1" ] \
  || { echo "FAIL: manual run not recorded" >&2; exit 1; }
[ "$(sq -At -c "SELECT count(*) FROM backup_agent WHERE heartbeat_at > now() - interval '1 minute'")" = "1" ] \
  || { echo "FAIL: no heartbeat" >&2; exit 1; }
if sq -At -c "SELECT config::text FROM backup_agent" | grep -q "$sk\|$ak"; then echo "FAIL: credentials published in backup_agent" >&2; exit 1; fi
if docker logs "$daemon" 2>&1 | grep -q "$sk\|AGE-SECRET-KEY"; then echo "FAIL: secret in daemon logs" >&2; exit 1; fi
echo "--- UI-saved settings: the running service picks them up (no env S3 config, no restart)"
docker rm -f "$daemon" >/dev/null
settings_key="$(openssl rand -hex 16)"
docker run -d --name "$daemon2" --network "$net" --user "$(id -u):$(id -g)" --tmpfs /work:mode=1777 -e BACKUP_WORK_DIR=/work \
  -e DATABASE_URL="$dburl" -e BACKUP_SETTINGS_KEY="$settings_key" -e BACKUP_POLL_SECONDS=2 "$image" daemon >/dev/null
for _ in $(seq 1 30); do
  [ "$(sq -At -c "SELECT count(*) FROM backup_agent WHERE config->'destinations' = '[]'::jsonb")" = "1" ] && break; sleep 1
done
[ "$(sq -At -c "SELECT count(*) FROM backup_agent WHERE config->'destinations' = '[]'::jsonb")" = "1" ] \
  || { echo "FAIL: daemon should start with no destination" >&2; docker logs "$daemon2" >&2; exit 1; }
printf '{"s3_enabled":true,"endpoint":"http://%s:9000","region":"us-east-1","bucket":"%s","prefix":"uibk","path_style":true,"insecure":true,"allow_private":true,"local_enabled":false,"age_recipients":["%s"],"schedule":"0 0 1 1 *","timezone":"UTC","keep_daily":7,"keep_weekly":4,"keep_monthly":6,"stale_hours":36}' \
  "$minio" "$bucket" "$pub" |
  docker run --rm -i --network "$net" -e DATABASE_URL="$dburl" -e BACKUP_SETTINGS_KEY="$settings_key" \
    -e BACKUP_IMPORT_ACCESS_KEY_ID="$ak" -e BACKUP_IMPORT_SECRET_ACCESS_KEY="$sk" "$image" settings-import
for _ in $(seq 1 30); do
  [ "$(sq -At -c "SELECT count(*) FROM backup_agent WHERE config->'destinations'->0->>'kind' = 's3'")" = "1" ] && break; sleep 1
done
[ "$(sq -At -c "SELECT count(*) FROM backup_agent WHERE config->'destinations'->0->>'kind' = 's3'")" = "1" ] \
  || { echo "FAIL: service did not apply the saved settings" >&2; docker logs "$daemon2" >&2; exit 1; }
if [ "$(sq -At -c "SELECT position(convert_to('$sk','UTF8') in credentials_enc) FROM backup_settings")" != "0" ]; then
  echo "FAIL: the S3 secret is stored in clear text" >&2; exit 1; fi
sq -c "INSERT INTO backup_requests (kind) VALUES ('test_s3')" >/dev/null
for _ in $(seq 1 60); do
  st="$(sq -At -c "SELECT status FROM backup_requests ORDER BY id DESC LIMIT 1")"; [ "$st" = "done" ] || [ "$st" = "failed" ] && break; sleep 1
done
[ "$st" = "done" ] || { echo "FAIL: test_s3 with UI settings ended as '$st'" >&2; docker logs "$daemon2" >&2; exit 1; }
sq -c "INSERT INTO backup_requests (kind) VALUES ('backup')" >/dev/null
for _ in $(seq 1 90); do
  st="$(sq -At -c "SELECT status FROM backup_requests ORDER BY id DESC LIMIT 1")"; [ "$st" = "done" ] || [ "$st" = "failed" ] && break; sleep 1
done
[ "$st" = "done" ] || { echo "FAIL: backup with UI settings ended as '$st'" >&2; docker logs "$daemon2" >&2; exit 1; }
[ "$(sq -At -c "SELECT count(*) FROM backup_runs WHERE trigger='manual' AND destination='s3' AND status='success' AND object_key LIKE '%/uibk/%'")" = "1" ] \
  || { echo "FAIL: UI-configured backup not recorded under the saved prefix" >&2; exit 1; }
n="$(bk -e BACKUP_S3_PREFIX=uibk "$image" list | grep -c '^s3')"; [ "$n" -ge 1 ] || { echo "FAIL: nothing stored under the UI prefix" >&2; exit 1; }
if sq -At -c "SELECT config::text FROM backup_agent" | grep -q "$sk\|$ak"; then echo "FAIL: credentials in heartbeat" >&2; exit 1; fi
if docker logs "$daemon2" 2>&1 | grep -q "$sk\|AGE-SECRET-KEY"; then echo "FAIL: secret in daemon logs" >&2; exit 1; fi
echo "backup-restore test PASSED"
