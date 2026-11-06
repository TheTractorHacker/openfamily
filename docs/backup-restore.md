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
| `scripts/backup-restore.test.sh` | End-to-end test: scratch DB, all migrations, seed, backup, encrypt, verify, plus negative cases (wrong passphrase, truncated file). Run in CI by `.github/workflows/backup-restore.yml`. |

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
