-- 000025_locations_unique_device_ts.down.sql
-- Deleted duplicate rows are not restored.
DROP INDEX IF EXISTS idx_locations_device_ts_unique;
