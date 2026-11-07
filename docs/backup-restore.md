# Backup and restore

The family database (Postgres + TimescaleDB, volume `pgdata`) holds location
history, so backups are as sensitive as the live data. Encrypt any copy that
leaves the host.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/backup.sh [file]` | `pg_dump --format=custom` of the running `postgres` service into `backups/` (mode 700/600). `BACKUP_KEEP=N` prunes old automatic backups. With `BACKUP_PASSPHRASE_FILE=/path` the dump is encrypted (AES-256-CBC, PBKDF2 600k iterations) and written as `*.dump.enc`. |
| `scripts/restore.sh <file> [--yes]` | DESTRUCTIVE. Stops the api, recreates the database, runs `timescaledb_pre_restore()`, `pg_restore`, `timescaledb_post_restore()`, restarts the api. `.enc` files need `BACKUP_PASSPHRASE_FILE`. |
| `scripts/verify-backup.sh <file>` | Restores the backup into a throwaway TimescaleDB container (the image pinned in `docker-compose.yml`), never the live database, and prints a row count per table. Exits non-zero if the restore errors, the schema is empty, or counts differ from `--expect-counts FILE` / `--source-container NAME`. |
| `scripts/restore.sh --from-s3 [latest\|NAME]` | Same restore, but downloads from your S3 bucket first: SHA-256 checked against the manifest, then age-decrypted with `BACKUP_AGE_IDENTITY_FILE`. `--from-local` does the same for the `backup` service's local directory. See [S3 and scheduled backups](#s3-and-scheduled-backups). |
| `scripts/verify-backup.sh --from-s3 [latest\|NAME]` | Download, verify, decrypt and restore into the throwaway container; never touches production. |
| `scripts/backup-restore.test.sh` | End-to-end test: scratch DB, all migrations, seed, backup, encrypt, verify, plus negative cases (wrong passphrase, truncated file); then the S3 round trip against a throwaway MinIO (see below). Run in CI by `.github/workflows/backup-restore.yml`. |

Typical cron entry (daily, encrypted, keep 14):

```cron
15 3 * * *  cd /opt/openfamily && BACKUP_KEEP=14 BACKUP_PASSPHRASE_FILE=/root/.of-backup-pass ./scripts/backup.sh && ./scripts/verify-backup.sh "$(ls -1t backups/openfamily-*.enc | head -1)"
```

Keep the passphrase file outside `backups/` and outside the copy that is
shipped off-host (password manager). A backup without its passphrase is
unrecoverable by design.

## Volume snapshots

`pg_dump` is the supported path. A filesystem/LVM/ZFS/cloud snapshot of the
`pgdata` volume is an acceptable *additional* layer, but only crash-consistent:
snapshot with the postgres container stopped (or use `pg_backup_start`), restore
into the same image tag/digest, and never mix a snapshot with a different
Postgres major version.

## RPO and RTO

| | Target | How it is achieved |
|---|---|---|
| RPO (data you can lose) | equal to the backup interval: 24 h with the daily cron above; 1 h with an hourly cron | Location points are re-sent by phones that were offline, so recent loss is partly self-healing; history older than the last backup is not. |
| RTO (time to recover) | under 30 min for a typical family instance (a few GB) | `docker compose up -d postgres`, `scripts/restore.sh`, api start. Restore time scales with dump size; measure on your hardware with `time scripts/verify-backup.sh <file>`. |

Measured here: `scripts/backup-restore.test.sh` (migrations + seed + 2 verified
restores + 2 negative cases) passed on a heavily loaded development host in
about 9.5 minutes, dominated by container start-up; this is a functional result,
not a performance benchmark. Record your own RTO from a real backup at least
once per quarter (run `verify-backup.sh` on a production dump).

## Restore drill checklist

1. `./scripts/verify-backup.sh <latest backup>` prints `VERIFIED` and plausible row counts (`users`, `locations`).
2. Compare counts with production (`--source-container` against a live container, or `SELECT count(*)`).
3. Confirm the passphrase works from the off-host copy of the key.
4. Only then rely on the backup; schedule the drill (CI runs the automated variant weekly).

## S3 and scheduled backups

The optional `backup` compose service (profile `backup`) replaces host cron and
adds off-site copies. Every night it streams `pg_dump` through
[age](https://age-encryption.org) encryption, writes the result to a local
directory and/or any S3-compatible bucket (AWS S3, Backblaze B2, Wasabi,
Cloudflare R2, MinIO, ...), uploads a SHA-256 manifest next to it, applies
retention, and records every run in the database so the admin **System** page
shows the truth. `scripts/backup.sh` keeps working unchanged; you can use
either or both.

```
postgres --pg_dump--> age encrypt (public key) --> /work (RAM, ciphertext only)
                                                   |--> ./backups   (optional)
                                                   '--> s3://bucket/prefix/openfamily-<UTC>.dump.age
                                                        s3://bucket/prefix/openfamily-<UTC>.manifest.json  (written last)
```

Properties:

- **Client-side encryption.** The dump is encrypted before it leaves the
  container; the plaintext never touches disk. The server only holds the
  *public* key, so a stolen server or bucket cannot decrypt old backups.
  Uploading an unencrypted dump to S3 is refused unless you set
  `BACKUP_ALLOW_UNENCRYPTED=true`.
- **Integrity.** The manifest records size and SHA-256 of the stored object.
  Restore checks both *before* decrypting; age's authenticated encryption then
  detects any modification inside the stream.
- **Multipart, retries.** Uploads are multipart (16 MiB parts, automatic growth
  for huge dumps); each request retries with backoff, and the whole upload is
  retried 3 times with a size check afterwards.
- **TLS required.** A plain `http://` endpoint is rejected unless
  `BACKUP_S3_INSECURE=true` (meant for a MinIO on your own private network).
- **Credentials never printed.** They are read from the environment or `_FILE`
  secrets, scrubbed from every error, log line, run record and API response,
  and are never available to the API container.

### Quick start 1: in the admin panel (recommended)

1. Start the service once (it needs no S3 settings to start):
   `docker compose --profile backup up -d --build backup`. Add `backup` to
   `COMPOSE_PROFILES` in `.env` so it survives `docker compose up -d`.
2. Open **System health > Backups > Settings**.
3. **Destinations:** switch on *S3-compatible storage* and fill endpoint
   (empty for AWS), region, bucket, folder, and the access key id and secret.
   The secret is write-only: after saving, the page only shows *Set ...ABCD* with
   *Replace* and *Clear*. Switch on *Local disk* as well if you want copies on this machine.
4. **Encryption:** press *Generate key pair*. The pair is created in your
   browser; the page shows the private key once with *Copy* and *Download*, you
   confirm you stored it, and only the public key is filled in. The server never
   sees or stores the private key. **If you lose it, no backup can be restored.**
5. **Schedule** (daily time or cron, plus time zone) and **Retention**, then
   *Test connection* (writes, reads and deletes a small object using the values
   in the form, saved or not) and *Save settings*. The backup service applies
   saved settings within a few seconds without a restart.
6. Press *Back up now*, then do a restore drill (below).

How settings are combined: **environment variables win**. A setting present in
the `backup` service's environment (`.env`) is *pinned*: the form shows it
read-only with a "Set by environment" badge. Everything the environment leaves
empty comes from the UI, then from built-in defaults. Every field shows whether
its value is from the environment, saved in the UI, or the default.

**Where the secret lives, honestly.** The S3 key id and secret are stored in the
`backup_settings` table, encrypted with AES-256-GCM under a key derived (HKDF-SHA256,
label `openfamily/backup-settings/v1`) from `BACKUP_SETTINGS_KEY`, or from
`JWT_SECRET` if you do not set it. A database dump or a stolen backup of the
database alone therefore does not reveal the key. But the API and the backup
service both need that secret to read it, so **anyone who has both the database
and the server environment can decrypt it**, exactly as they could read a
`BACKUP_S3_SECRET_ACCESS_KEY` from `.env`. Set a dedicated `BACKUP_SETTINGS_KEY`
(`openssl rand -hex 32`) if you want it independent of `JWT_SECRET`; changing
`JWT_SECRET` or this value later makes saved credentials unreadable (the UI says
so; enter them again). Use a bucket key scoped to the backup folder.

**Disaster recovery needs the key outside the database.** Credentials saved in
the UI live in the database you would be restoring. Keep a copy of the S3 key in
your password manager (or in `.env` as `BACKUP_S3_*`) so `restore.sh --from-s3`
works on a fresh machine.

**Network policy.** Endpoints must be https unless *Allow plain HTTP* is on.
Link-local and cloud-metadata addresses (169.254.0.0/16, fd00:ec2::254, ...) are
always refused, checked again on every connection after DNS resolution.
Loopback and private (LAN) addresses are refused unless *Allow private network
address* is on, because a MinIO on your LAN is a legitimate target.

**Credentials are bound to their destination.** A saved key is stored together
with a fingerprint of the endpoint, plain-HTTP flag, private-network flag and
region it was entered for (inside the encrypted blob). If you change any of
those, in Save or in *Test connection*, you must type the access key and secret
again; the saved key is never sent to a different address, so a hijacked admin
session cannot point the test at a host it controls to collect it. Credentials
from `.env` likewise pin the endpoint, plain-HTTP and private-network settings
to `.env` (read-only in the panel). Keys saved by earlier builds have no
fingerprint and must be entered once more. IPv6 transition addresses (NAT64,
6to4, Teredo, IPv4-compatible) are refused unless *Allow private network
address* is on, and the IPv4 address they embed is checked with the same rules,
so metadata or LAN targets cannot be disguised that way.

### Quick start 2: with environment variables

1. **Create the key pair on your own computer** (not on the server):

   ```sh
   age-keygen -o openfamily-backup.key     # prints "Public key: age1..."
   # no age installed?  docker run --rm openfamily-backup:local keygen > openfamily-backup.key
   ```

   Put `openfamily-backup.key` in your password manager and on a second,
   offline medium. **Never copy it to the server.** Only the `age1...` public
   key goes into `.env`.
2. **Create a bucket and an access key** (least-privilege policy below).
3. **Edit `.env`** (see `.env.example` for every variable):

   ```sh
   BACKUP_AGE_RECIPIENT=age1xxxxxxxx...
   BACKUP_S3_BUCKET=my-openfamily-backups
   BACKUP_S3_REGION=eu-central-1
   BACKUP_S3_PREFIX=openfamily
   BACKUP_S3_ACCESS_KEY_ID=...
   BACKUP_S3_SECRET_ACCESS_KEY=...
   # optional: also keep copies on this machine
   BACKUP_LOCAL_DIR=/backups
   ```

   `chmod 600 .env`. To keep the secret out of the process environment, put it
   in `deploy/backup/s3-secret` and set
   `BACKUP_S3_SECRET_ACCESS_KEY_FILE=/run/backup-secrets/s3-secret`.
4. **Start it and test the connection:**

   ```sh
   docker compose --profile backup up -d --build backup
   docker compose --profile backup run --rm backup test-s3     # writes, reads and deletes a probe object
   docker compose --profile backup run --rm backup run         # first backup now
   ```

   Or use the **Backups** card on the admin System page (*Test S3 connection*,
   *Back up now*). Add `backup` to `COMPOSE_PROFILES` in `.env` so it survives
   `docker compose up -d`.
5. **Do a restore drill now** (below). An untested backup is a hope, not a backup.

### Configuration reference

Every variable is optional if you use the admin panel. A variable you set here
overrides, and locks, the matching field in the UI. Leave it empty to manage it
in the UI.

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_SCHEDULE` | `15 3 * * *` | 5-field cron (`min hour dom month dow`; `*`, lists, ranges, `*/n`). |
| `BACKUP_TZ` | `UTC` | IANA time zone the schedule is evaluated in (DST-aware). A time skipped by a DST jump is skipped; missed runs while the service was down are **not** replayed (set `BACKUP_RUN_ON_START=true` to take one on every start). |
| `BACKUP_AGE_RECIPIENT` | | age public key(s), comma separated (several = any of them can decrypt; use for key rotation or a second custodian). |
| `BACKUP_AGE_PASSPHRASE_FILE` | | Alternative: age passphrase mode (min. 12 chars) from a file. Weaker, see "Encryption and keys". |
| `BACKUP_S3_ENDPOINT` | AWS | Host or `https://host[:port]`. Empty = AWS S3. |
| `BACKUP_S3_REGION` | | Region (`auto` for R2). |
| `BACKUP_S3_BUCKET` / `BACKUP_S3_PREFIX` | / `openfamily` | Bucket and key prefix. Everything the service creates lives directly under the prefix. |
| `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` | | Credentials, or `..._FILE` variants. |
| `BACKUP_S3_PATH_STYLE` | `false` | `true` for MinIO and some self-hosted stores. |
| `BACKUP_S3_STORAGE_CLASS` | | e.g. `STANDARD_IA`, `GLACIER_IR` (AWS). Leave empty for B2/Wasabi/R2/MinIO. |
| `BACKUP_S3_INSECURE` | `false` | Allow plain HTTP. Only for a MinIO on a private network. |
| `BACKUP_LOCAL_DIR` / `BACKUP_LOCAL_PATH` | | In-container dir (use `/backups`) / host dir (default `./backups`). The container runs as `BACKUP_UID:BACKUP_GID` (default 1000:1000); it must be able to write the host dir. |
| `BACKUP_KEEP_DAILY` / `_WEEKLY` / `_MONTHLY` | `7` / `4` / `6` | Retention. `0` disables a tier; all three `0` keeps everything. |
| `BACKUP_RETENTION_DRY_RUN` | `false` | Log what would be deleted, delete nothing. |
| `BACKUP_S3_ALLOW_PRIVATE` | `true` for env endpoints | Allow loopback/LAN endpoints. Link-local/metadata addresses are always refused. |
| `BACKUP_SETTINGS_KEY` | `JWT_SECRET` | Secret the UI-saved S3 credentials are encrypted under (HKDF). Same value must reach the API and the backup service (compose does this). |
| `BACKUP_STALE_HOURS` | `36` | The System page raises a warning when the newest *successful* backup is older. |
| `BACKUP_WORK_SIZE` | `4g` | Size of the RAM-backed staging area for the encrypted dump. Raise it above your compressed dump size. |

### Provider examples

All use the same variables; only the endpoint/addressing differ.

```sh
# AWS S3
BACKUP_S3_REGION=eu-central-1
BACKUP_S3_STORAGE_CLASS=STANDARD_IA

# Backblaze B2 (S3-compatible API; endpoint is shown on the bucket page)
BACKUP_S3_ENDPOINT=s3.us-west-004.backblazeb2.com
BACKUP_S3_REGION=us-west-004

# Wasabi
BACKUP_S3_ENDPOINT=s3.eu-central-1.wasabisys.com
BACKUP_S3_REGION=eu-central-1

# Cloudflare R2 (use an R2 API token with Object Read & Write, scoped to the bucket)
BACKUP_S3_ENDPOINT=<accountid>.r2.cloudflarestorage.com
BACKUP_S3_REGION=auto

# MinIO on your LAN (no TLS)
BACKUP_S3_ENDPOINT=http://minio.lan:9000
BACKUP_S3_INSECURE=true
BACKUP_S3_PATH_STYLE=true
```

### Least-privilege bucket policy

The service needs to list, write, read (restore/verify and the connection
test) and delete (retention) objects under its prefix, and nothing else.
AWS IAM policy for the access key:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::my-openfamily-backups",
      "Condition": { "StringLike": { "s3:prefix": ["openfamily/*", "openfamily"] } } },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-openfamily-backups/openfamily/*" }
  ]
}
```

Add `s3:AbortMultipartUpload` and `s3:ListBucketMultipartUploads` if you want
failed uploads cleaned up by the client (a bucket lifecycle rule "abort
incomplete multipart uploads after 7 days" does the same and is recommended).
B2, Wasabi and R2 offer equivalent bucket-scoped keys; scope the key to this
one bucket, never to the whole account.

### Ransomware and deletion protection

An attacker who takes over the server obtains the S3 key and can delete what
that key can delete. Layer the bucket so that does not end your backups:

- **Enable versioning** (and a lifecycle rule that expires *noncurrent*
  versions after, say, 30-90 days). A delete or overwrite then only adds a
  version you can restore.
- **Or use Object Lock (compliance/governance mode)** with a retention longer
  than your keep window. Locked objects cannot be deleted by the key at all.
  The service's retention step will then log a warning for objects still
  locked; that is expected. If you rely on Object Lock or lifecycle rules for
  expiry, set `BACKUP_KEEP_DAILY=0 BACKUP_KEEP_WEEKLY=0 BACKUP_KEEP_MONTHLY=0`
  and drop `s3:DeleteObject` from the policy (the connection test then reports
  *delete: FAILED*, which is correct in that setup).
- Keep **a second copy** under a different account/provider if the data matters
  (point a second service instance, or `rclone`, at the first bucket).
- Alert on silence: the System page warns after `BACKUP_STALE_HOURS`, and also
  when the `backup` service stops reporting.

### Encryption and keys

- **Key pair mode (recommended).** The server holds only the public key. The
  private key (`AGE-SECRET-KEY-...`) stays with you. The service refuses to
  start if `BACKUP_AGE_RECIPIENT` contains a private key.
- **Passphrase mode.** The passphrase file must be readable by the service, so
  anyone who compromises the server can decrypt every backup. Use it only when
  you cannot manage a key pair. Use a long random value.
- **If you lose the private key (or passphrase), every encrypted backup is
  permanently unreadable.** There is no recovery and no backdoor. Keep at least
  two independent copies (password manager + printed/offline), and test the key
  with `verify-backup.sh --from-s3` after storing it.
- **Rotation.** Generate a new pair, set
  `BACKUP_AGE_RECIPIENT=<new>,<old>` for a while (new backups open with either
  key), later drop `<old>`. Old backups still need the old private key.
- The format is plain age: you can decrypt without OpenFamily:
  `age -d -i openfamily-backup.key openfamily-<ts>.dump.age > restore.dump`
  (check the SHA-256 in the manifest first: `sha256sum openfamily-<ts>.dump.age`).

### Retention

After each successful upload the service keeps the newest backup per day for
`BACKUP_KEEP_DAILY` days, per ISO week for `_WEEKLY` weeks and per month for
`_MONTHLY` months (days are counted in `BACKUP_TZ`), and deletes the rest. It
only touches objects named `openfamily-<UTC timestamp>.dump[.age]` plus their
manifest, **never deletes the newest complete backup**, ignores everything else
in the prefix (including backups made by `scripts/backup.sh`), and only prunes
a destination after a successful backup to it. Preview with
`docker compose --profile backup run --rm backup prune --dry-run` or
`BACKUP_RETENTION_DRY_RUN=true`.

### Admin panel and System page

System health has a **Backups** card: configured destinations (bucket and
host, never keys), encryption mode, last success / failure, size and duration,
next scheduled run, retention, and recent runs. *Back up now* and *Test S3
connection* are platform-admin only, rate limited (4 and 10 per hour per
admin), allow one request at a time, and are audit logged
(`admin.backup.run`, `admin.backup.test_s3`). They only *queue* a request: the
`backup` service picks it up within seconds. The API never holds S3
credentials, the age key or the dump tools, so nothing sensitive can appear in
an API response. Warnings appear as banners when there is no backup, the last
success is older than `BACKUP_STALE_HOURS`, the latest attempt failed, or the
service stopped reporting.

### Restore and restore drill

```sh
# 1. Verify without touching production (scratch container; prints per-table row counts)
export BACKUP_AGE_IDENTITY_FILE=~/openfamily-backup.key       # on the machine that has the private key
./scripts/verify-backup.sh --from-s3 latest
# 2. Real restore (stops the api, replaces the database, starts the api again)
./scripts/restore.sh --from-s3 latest        # or: --from-s3 openfamily-20261107T031500Z
```

Both read `BACKUP_S3_*` from the environment or `.env`, download through the
backup image in a throwaway container (the private key is mounted read-only
into that container only), refuse a checksum mismatch, decrypt, and then use
the normal restore path. For a disaster on a fresh machine: install Docker,
clone the repo, create `.env` with `POSTGRES_PASSWORD`, `JWT_SECRET` (the old
`JWT_SECRET` keeps existing sessions valid) and the `BACKUP_S3_*` values, `docker
compose up -d postgres`, then `./scripts/restore.sh --from-s3 latest`. Drill
checklist, quarterly:

1. `verify-backup.sh --from-s3 latest` prints `VERIFIED` and plausible `users`/`locations` counts.
2. Restore **a named** backup you did not just create (`--from-s3 openfamily-<ts>` from a month ago).
3. Confirm the private key from its off-site copy (not the working copy) decrypts it.
4. Note the time taken (your real RTO) and the backup age (your real RPO).

### Costs

Backups are compressed Postgres dumps; a family's location history is typically
tens to a few hundred MB. With the default retention (about 17 objects) that is
well under 10 GB, i.e. cents per month on B2/Wasabi/R2 (R2 has no egress fees;
AWS charges for restore egress, and Glacier classes add retrieval delays and
minimum-duration fees: use `STANDARD_IA` or `GLACIER_IR`, not Deep Archive).
Check your provider's current price list; none was queried for this document.

### Security review of the credential and encryption path

Assumptions and what was checked, with the residual risks stated plainly:

- *S3 secret on the server.* It lives in `.env` (mode 600) or a secret file and
  in the `backup` container's environment (visible to anyone with Docker
  access via `docker inspect`; use `_FILE` secrets to avoid that). It is **not**
  passed to the API container. Use a key scoped to one bucket/prefix.
- *Compromised server.* The attacker can use the S3 key (delete/overwrite
  backups: mitigate with versioning/Object Lock), and sees plaintext data at
  runtime anyway. They cannot decrypt *past* backups from the public key. In
  passphrase mode they can, which is why key-pair mode is recommended.
- *Forged backups.* age encryption proves nothing about who wrote a file:
  anyone with the public key and write access to the bucket can add a valid
  encrypted dump and a matching manifest. The manifest is integrity
  (corruption/truncation), not authenticity. `restore latest` would pick a
  forged newest backup, and `pg_restore` of a hostile dump can run arbitrary SQL.
  Mitigations: keep write access to the bucket narrow, enable Object Lock /
  versioning, verify (`verify-backup.sh`) before restoring, and restore by an
  explicit `NAME` you recognise from the System page's recent runs
  (`object_key` is recorded). Signed backups are not implemented.
- *Private key handling.* The service never reads a private key; supplying one
  as the recipient aborts start-up with a message that does not echo it; error
  and log text is scrubbed of the S3 secret, DB password and any
  `AGE-SECRET-KEY-` string; `keygen` prints the private key to stdout only
  when you ask for it. Restore tooling mounts the key read-only into a
  throwaway container and passes S3 variables by name (not on the command line).
- *Disk exposure.* The plaintext dump is never written to disk by the service
  (pipe into the encryptor; staging area is a tmpfs holding ciphertext).
  `restore.sh`/`verify-backup.sh` decrypt into a `0700` temp dir that is
  removed on exit; on a shared machine prefer restoring on a trusted host.
- *Transport.* TLS with normal certificate verification is mandatory;
  `BACKUP_S3_INSECURE` is explicit and shown in no UI. Custom CA bundles are
  not supported: a MinIO with a private CA should be reached over a trusted
  network with the insecure flag, or fronted by a publicly trusted certificate.
- *UI-saved credentials.* Sealed with AES-256-GCM (random nonce, AAD bound to the
  column) under an HKDF-derived key; never returned by any endpoint (GET reports
  presence and the last four characters of the key id), never in audit entries
  (only changed field names, e.g. `credentials(replaced)`), never in error text, the
  heartbeat or logs. Residual risks: (1) an attacker with database AND server
  environment reads them; (2) the transient "test unsaved values" request stores
  the sealed form in `backup_requests.payload_enc` until the service finishes it
  (then it is nulled; a crashed run is nulled at the next start); (3) the browser
  holds the typed secret in memory until saved, and a malicious browser extension
  could read it; (4) any platform admin can *replace* the destination, so a
  compromised admin account can redirect future backups to a bucket it controls
  (they stay encrypted to your public key, but it can also swap the public key:
  review `admin.backup.settings` audit entries and keep admin MFA on).
  Environment-pinned fields cannot be changed this way.
- *SSRF.* The S3 endpoint is attacker-controllable by a platform admin, so the
  service refuses link-local/metadata addresses always, and private addresses
  unless allowed, at save time and at dial time (defeating DNS rebinding). The
  connection test only writes and deletes one object under the configured prefix.
- *Admin API abuse.* The buttons only enqueue a fixed action, cannot change
  destinations or keys, and are rate limited, serialized and audited.
- *Clock.* S3 request signing needs the host clock within about 15 minutes.
- *Not covered:* provider-side compromise of your account, object-lock misconfiguration,
  and integrity of the `backup` image itself (it is built locally from this repository).

### What the automated test covers

`scripts/backup-restore.test.sh` runs the real service binary against a
throwaway MinIO: connection test, TLS refusal, wrong-secret failure (secret not
in output), encrypted backup to local dir and S3 with `backup_runs` rows,
`verify-backup.sh --from-s3` and `--from-local` with row-count comparison
against the source, wrong private key, a tampered object (checksum mismatch
before decryption), retention dry-run/real with the newest surviving, and the
daemon serving `backup_requests`. It has **not** been run against real AWS S3,
Backblaze B2, Wasabi or Cloudflare R2; the endpoints above follow each
provider's S3-compatibility documentation and the MinIO result, not a live test.
