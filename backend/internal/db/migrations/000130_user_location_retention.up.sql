-- 000130_user_location_retention.up.sql
-- Optional per-user location history window (days). NULL = the deployment
-- default (LOCATION_RETENTION_DAYS). The API caps it at the deployment value, so
-- a user can only shorten retention, never extend it.
ALTER TABLE users ADD COLUMN IF NOT EXISTS location_retention_days integer
    CHECK (location_retention_days IS NULL OR location_retention_days > 0);
