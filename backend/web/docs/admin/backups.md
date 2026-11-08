# Backups and restore

Your family's data lives in one Docker volume. Back it up before you need it.

## Quick backup

```bash
./scripts/backup.sh                       # writes ./backups/openfamily-<time>.dump
./scripts/verify-backup.sh backups/<file>.dump   # restore into a scratch database and compare
```

Schedule it daily with cron and copy `backups/` off the machine (another disk,
a cloud bucket). The admin **System** page warns when the last backup is
missing or older than 48 hours.

## Scheduled, encrypted off-site backups

Turn on the `backup` compose profile and enter an S3-compatible bucket (AWS,
Backblaze B2, Wasabi, Cloudflare R2, MinIO) in **Settings, Backups**. Copies are
encrypted on your server before upload and old ones are removed by a retention
rule. **Back up now** and **Test S3** buttons are on the same card.

## Restore

```bash
./scripts/restore.sh backups/<file>.dump   # DESTRUCTIVE: asks you to type RESTORE
```

## Do not forget

- Back up your `.env` (it holds the secrets that unlock sealed settings).
- Turn on disk encryption on the machine.
- Keep the Android signing key safe if you build your own app.

Everything in depth, including recovery objectives and snapshots:
[Backup and restore](../backup-restore.md).
