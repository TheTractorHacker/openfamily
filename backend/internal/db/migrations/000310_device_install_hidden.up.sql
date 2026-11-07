-- A stable per-install id lets POST /devices reuse a device row instead of
-- creating a new one on every login/reinstall; hidden_at lets an admin hide
-- stale device rows from Fleet health without deleting location history.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS install_id TEXT NOT NULL DEFAULT '';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS hidden_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_devices_user_install ON devices (user_id, platform, install_id) WHERE install_id <> '';
