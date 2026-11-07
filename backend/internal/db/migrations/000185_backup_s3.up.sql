-- 000185_backup_s3.up.sql
-- Scheduled and S3 backups. backup_runs now records every attempt (success or
-- failure) with its destination; backup_agent is the heartbeat + non-secret
-- configuration summary published by the optional `backup` compose service;
-- backup_requests is the queue the admin panel uses to ask that service for a
-- "back up now" run or an S3 connection test (the API container never holds
-- S3 credentials or the dump tools). Holds no personal data and no secrets.
-- Idempotent.
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS status      TEXT    NOT NULL DEFAULT 'success';
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS destination TEXT    NOT NULL DEFAULT 'local';
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS encrypted   BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS object_key  TEXT;
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS error       TEXT;
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS duration_ms BIGINT;
ALTER TABLE backup_runs ADD COLUMN IF NOT EXISTS trigger     TEXT    NOT NULL DEFAULT 'script';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'backup_runs_status_check') THEN
    ALTER TABLE backup_runs ADD CONSTRAINT backup_runs_status_check CHECK (status IN ('success', 'failed'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_backup_runs_status_taken ON backup_runs (status, taken_at DESC);

CREATE TABLE IF NOT EXISTS backup_agent (
    id           SMALLINT PRIMARY KEY CHECK (id = 1),
    heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    version      TEXT NOT NULL DEFAULT '',
    next_run_at  TIMESTAMPTZ,
    config       JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS backup_requests (
    id           BIGSERIAL PRIMARY KEY,
    kind         TEXT NOT NULL CHECK (kind IN ('backup', 'test_s3')),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'failed')),
    requested_by UUID REFERENCES users(id) ON DELETE SET NULL,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    message      TEXT
);
CREATE INDEX IF NOT EXISTS idx_backup_requests_open ON backup_requests (id) WHERE status IN ('pending', 'running');
