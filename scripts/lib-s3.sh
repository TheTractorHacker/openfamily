#!/usr/bin/env bash
# Shared helper for restore.sh / verify-backup.sh: download a backup written by
# the `backup` service (compose profile "backup"), verify its SHA-256 against
# the manifest and decrypt it, using the backup image in a THROWAWAY container.
# The private age key stays on the host: it is mounted read-only into that one
# container for the duration of the call and is never copied anywhere.
#
# Source this file; then:  fetch_backup <s3|local> <latest|openfamily-TS> <out-file>
#
# Env: BACKUP_S3_ENDPOINT/REGION/BUCKET/PREFIX/PATH_STYLE/INSECURE and
#      BACKUP_S3_ACCESS_KEY_ID/BACKUP_S3_SECRET_ACCESS_KEY (also read from ./.env)
#      BACKUP_AGE_IDENTITY_FILE     host path of the age PRIVATE key (AGE-SECRET-KEY-...)
#      BACKUP_AGE_PASSPHRASE_FILE   host path of the passphrase file (passphrase backups)
#      BACKUP_LOCAL_PATH            host directory of local backups (default ./backups)
#      BACKUP_IMAGE                 default openfamily-backup:local (built on demand)
#      BACKUP_FETCH_NETWORK         docker network to attach (e.g. for a local MinIO)

# Export BACKUP_S3_* from .env without sourcing it (no code execution, values
# already in the environment win).
load_backup_env() {
  [ -f .env ] || return 0
  local line k v
  while IFS= read -r line; do
    case "$line" in BACKUP_S3_*=*|BACKUP_LOCAL_PATH=*|BACKUP_AGE_IDENTITY_FILE=*) ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done < .env
}

fetch_backup() { # $1 store  $2 which  $3 out file
  local store="$1" which="${2:-latest}" out="$3"
  local image="${BACKUP_IMAGE:-openfamily-backup:local}"
  load_backup_env
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Building the backup image (once)..." >&2
    docker compose --profile backup build backup >&2 || { echo "error: cannot build the backup image" >&2; return 1; }
  fi
  local outdir; outdir="$(dirname "$out")"
  local -a args=(run --rm --user "$(id -u):$(id -g)" -v "$outdir:/out")
  [ -n "${BACKUP_FETCH_NETWORK:-}" ] && args+=(--network "$BACKUP_FETCH_NETWORK")
  # Pass variables by NAME so values never appear in the process list.
  local v
  for v in BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET BACKUP_S3_PREFIX BACKUP_S3_PATH_STYLE BACKUP_S3_INSECURE \
           BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!v:-}" ] && args+=(-e "$v")
  done
  if [ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ]; then
    [ -r "$BACKUP_AGE_IDENTITY_FILE" ] || { echo "error: cannot read BACKUP_AGE_IDENTITY_FILE" >&2; return 2; }
    args+=(-v "$(readlink -f "$BACKUP_AGE_IDENTITY_FILE"):/run/age/identity:ro" -e BACKUP_AGE_IDENTITY_FILE=/run/age/identity)
  elif [ -n "${BACKUP_AGE_PASSPHRASE_FILE:-}" ]; then
    [ -r "$BACKUP_AGE_PASSPHRASE_FILE" ] || { echo "error: cannot read BACKUP_AGE_PASSPHRASE_FILE" >&2; return 2; }
    args+=(-v "$(readlink -f "$BACKUP_AGE_PASSPHRASE_FILE"):/run/age/passphrase:ro" -e BACKUP_AGE_PASSPHRASE_FILE=/run/age/passphrase)
  else
    echo "error: set BACKUP_AGE_IDENTITY_FILE (age private key file) or BACKUP_AGE_PASSPHRASE_FILE to decrypt" >&2
    return 2
  fi
  if [ "$store" = "local" ]; then
    args+=(-v "$(readlink -f "${BACKUP_LOCAL_PATH:-./backups}"):/backups:ro" -e BACKUP_LOCAL_DIR=/backups)
  elif [ -z "${BACKUP_S3_BUCKET:-}" ]; then
    echo "error: BACKUP_S3_BUCKET (and credentials) are not set; put them in .env or the environment" >&2
    return 2
  fi
  docker "${args[@]}" "$image" fetch -o "/out/$(basename "$out")" --from "$store" "$which"
}
