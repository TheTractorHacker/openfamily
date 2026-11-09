# Backups and restore

Your circles' data lives in one Docker volume (`pgdata`). Back it up before you need it.

## Quick backup

```bash
./scripts/backup.sh                       # writes ./backups/openfamily-<time>.dump
./scripts/verify-backup.sh backups/<file>.dump   # restore into a scratch database and compare
```

Schedule it daily with cron and copy `backups/` off the machine (another disk,
a cloud bucket). The admin **System** page warns when the last backup is
missing or older than 48 hours.

## Scheduled, encrypted off-site backups

Orbitly can also back up on a schedule by itself, to a local folder and/or an
S3-compatible bucket (AWS, Backblaze B2, Wasabi, Cloudflare R2, MinIO). Copies
are encrypted on your server before upload and old ones are removed by a
retention rule. You configure it in the admin web under **Settings, Backups**,
which also has **Back up now** and **Test S3** buttons. How to turn it on for
your installation and every option: [Backup and restore](../backup-restore.md#s3-and-scheduled-backups).

## Restore

```bash
./scripts/restore.sh backups/<file>.dump   # DESTRUCTIVE: asks you to type RESTORE
```

## Do not forget

- Back up your `.env` (it holds the secrets that unlock sealed settings). On a
  rented server keep `OPENFAMILY_DATA_KEY` in a password manager too.
- Back up the `server_device` volume (the server's own key). Losing it only
  means the server must be approved again on a phone.
- Turn on disk encryption on the machine.
- Keep the Android signing key safe if you build your own app.

Everything in depth, including recovery objectives and snapshots:
[Backup and restore](../backup-restore.md).
