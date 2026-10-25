-- 000050_alert_deliveries.down.sql
ALTER TABLE alerts DROP COLUMN IF EXISTS share_revoked_at;
ALTER TABLE alerts DROP COLUMN IF EXISTS share_expires_at;
DROP TABLE IF EXISTS alert_deliveries;
