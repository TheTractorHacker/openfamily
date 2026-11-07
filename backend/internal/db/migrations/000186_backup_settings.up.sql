-- 000186_backup_settings.up.sql
-- Backup settings editable from the admin UI. One row. `settings` is non-secret
-- JSON; `credentials_enc` is the S3 access key id + secret sealed with
-- AES-256-GCM under a key derived (HKDF) from BACKUP_SETTINGS_KEY or JWT_SECRET,
-- so it is useless without the server's environment. backup_requests gains an
-- encrypted payload used to test unsaved form values. Idempotent.
CREATE TABLE IF NOT EXISTS backup_settings (
    id              SMALLINT PRIMARY KEY CHECK (id = 1),
    settings        JSONB NOT NULL DEFAULT '{}'::jsonb,
    credentials_enc BYTEA,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by      UUID REFERENCES users(id) ON DELETE SET NULL
);
ALTER TABLE backup_requests ADD COLUMN IF NOT EXISTS payload_enc BYTEA;
