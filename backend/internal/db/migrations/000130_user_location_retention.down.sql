-- 000130_user_location_retention.down.sql
ALTER TABLE users DROP COLUMN IF EXISTS location_retention_days;
