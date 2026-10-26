-- 000101_sensor_events.down.sql
DROP VIEW IF EXISTS trip_events_effective;
ALTER TABLE users DROP COLUMN IF EXISTS driving_sensor_enabled;
DROP INDEX IF EXISTS idx_trip_events_started;
DROP INDEX IF EXISTS idx_trip_events_unlinked;
DROP INDEX IF EXISTS uq_trip_events_sensor;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'trip_events' AND column_name = 'source') THEN
        DELETE FROM trip_events WHERE source = 'sensor' OR trip_id IS NULL OR lat IS NULL OR lon IS NULL;
    END IF;
END $$;
ALTER TABLE trip_events DROP CONSTRAINT IF EXISTS trip_events_source_check;
ALTER TABLE trip_events DROP COLUMN IF EXISTS device_id;
ALTER TABLE trip_events DROP COLUMN IF EXISTS source;
ALTER TABLE trip_events ALTER COLUMN lat SET NOT NULL;
ALTER TABLE trip_events ALTER COLUMN lon SET NOT NULL;
ALTER TABLE trip_events ALTER COLUMN trip_id SET NOT NULL;
