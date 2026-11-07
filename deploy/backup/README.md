Optional secret files for the `backup` compose service (profile `backup`).
Mounted read-only at /run/backup-secrets. Files here are git-ignored.

Examples (chmod 600, owned by the BACKUP_UID user):
- `s3-secret` -> BACKUP_S3_SECRET_ACCESS_KEY_FILE=/run/backup-secrets/s3-secret
- `age-passphrase` -> BACKUP_AGE_PASSPHRASE_FILE=/run/backup-secrets/age-passphrase

Never put an age PRIVATE key here. See docs/backup-restore.md.
