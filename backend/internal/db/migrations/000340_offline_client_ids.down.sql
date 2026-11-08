DROP INDEX IF EXISTS idx_checkins_user_client_id;
DROP INDEX IF EXISTS idx_alerts_user_client_id;
ALTER TABLE checkins DROP COLUMN IF EXISTS client_id;
ALTER TABLE alerts DROP COLUMN IF EXISTS client_id;
