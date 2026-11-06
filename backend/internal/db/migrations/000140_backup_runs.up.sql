-- 000140_backup_runs.up.sql
-- Heartbeat written by scripts/backup.sh after each successful dump so the
-- admin system-health page can show the last backup time and flag a missing
-- recent one. Holds no personal data. Idempotent.
CREATE TABLE IF NOT EXISTS backup_runs (
    id         BIGSERIAL PRIMARY KEY,
    taken_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    size_bytes BIGINT NOT NULL DEFAULT 0 CHECK (size_bytes >= 0)
);
CREATE INDEX IF NOT EXISTS idx_backup_runs_taken ON backup_runs (taken_at DESC);
