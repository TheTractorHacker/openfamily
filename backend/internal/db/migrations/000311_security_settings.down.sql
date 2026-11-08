DROP TABLE IF EXISTS security_settings;
DROP INDEX IF EXISTS idx_refresh_sessions_client;
ALTER TABLE refresh_sessions DROP COLUMN IF EXISTS client_key;
