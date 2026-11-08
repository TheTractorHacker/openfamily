DROP INDEX IF EXISTS idx_devices_user_install;
ALTER TABLE devices DROP COLUMN IF EXISTS hidden_at;
ALTER TABLE devices DROP COLUMN IF EXISTS install_id;
