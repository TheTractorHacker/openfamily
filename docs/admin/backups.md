# Backups and restore

Your circles' data lives in one Docker volume. Orbitly backs it up for you.

## On by default

A normal install (`docker compose up -d`) also starts the **backup service**.
Without any setup it:

- takes a first backup a minute after it starts for the first time;
- then backs up every night at 03:15 (UTC; change it in Settings);
- writes the files to the `backups` folder next to `docker-compose.yml`;
- keeps the newest 7 daily, 4 weekly and 6 monthly backups and deletes older ones.

Everything is managed in the admin web under **Settings > Backups**: last
backup, next run, **Back up now**, and **Change settings** (schedule, retention,
encryption, S3). The **System health** page shows the last backup time and
warns when it is missing or too old.

These local backups are **not encrypted** until you add a key. That is fine
while they stay on the same machine (the database itself is not encrypted on
disk either). Before you copy them anywhere else, open **Settings > Backups >
Change settings**, press **Generate key pair** under Encryption and keep the
private key somewhere safe (a password manager). Without it, encrypted backups
cannot be restored.

## Copies somewhere else

A backup on the same disk does not survive a dead disk. Either copy the
`backups` folder off the machine now and then, or enter an S3-compatible
bucket (AWS, Backblaze B2, Wasabi, Cloudflare R2, MinIO) under **Settings >
Backups > Change settings**. Uploads to S3 must be encrypted.

## Existing servers

Servers installed before backups were on by default pick it up with:

```bash
git pull            # or ./scripts/upgrade.sh
mkdir -p backups    # if it does not exist yet; it must be writable by uid 1000
docker compose up -d
```

If the server runs as another user, set `BACKUP_UID` and `BACKUP_GID` in `.env`
to the owner of the `backups` folder (or `sudo chown 1000:1000 backups`). When
the folder is not writable, Settings > Backups shows exactly that, with the
command to fix it.

## Turning it off

Put `BACKUP_REPLICAS=0` in `.env` and run `docker compose up -d` again. Then
you are responsible for backups yourself, for example with
`./scripts/backup.sh` from cron.

## Manual backup

```bash
./scripts/backup.sh                              # writes ./backups/openfamily-<time>.dump
./scripts/verify-backup.sh backups/<file>.dump   # restore into a scratch database and compare
```

## Restore

```bash
./scripts/restore.sh backups/<file>.dump         # DESTRUCTIVE: asks you to type RESTORE
./scripts/restore.sh --from-local latest         # newest backup taken by the backup service
```

## The server's own key

The Orbitly server has its own identity (the key every phone pinned when an admin approved the server). It lives
in the Docker volume `server_device` (`/data/server-device`) and survives restarts, image rebuilds and
container recreation. It is created once and never regenerated while it exists. It is **not** in the database,
so the database backup does not contain it.

- `./scripts/backup.sh` with `BACKUP_PASSPHRASE_FILE` set also writes
  `backups/openfamily-<time>.server-key.tar.enc` (encrypted with the same passphrase). Without a passphrase the
  key directory is **not** saved: the secret key never goes into an unencrypted file.
- The nightly **backup service** does **not** include it (it runs as another user and cannot read the key
  directory). Honest gap: if you only use the backup service and lose the `server_device` volume, the server makes
  a new key and an admin phone has to approve it again (a prompt on the admin's phone, compare the code); the family's
  phones then pick it up by themselves. Run `./scripts/backup.sh` with a passphrase now and then, or copy the volume
  yourself.
- Restore the key onto a new machine after restoring the database:
  `BACKUP_PASSPHRASE_FILE=... ./scripts/restore-server-key.sh backups/<file>.server-key.tar.enc`.
- Never run `docker compose down -v` (or `docker volume rm`) unless you want a new server key.
- To replace the key on purpose (for example you think the volume leaked), use **Replace the server key** as the
  server's admin; nothing else changes the key.

## Do not forget

- Back up your `.env` (it holds the secrets that unlock sealed settings).
- Turn on disk encryption on the machine.
- Keep the Android signing key safe if you build your own app.

Everything in depth, including recovery objectives and snapshots:
[Backup and restore](../backup-restore.md).
