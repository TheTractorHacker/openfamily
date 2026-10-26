-- 000100_trip_events.down.sql
DROP INDEX IF EXISTS idx_trip_events_trip;
DROP INDEX IF EXISTS idx_trip_events_user_started;
DROP TABLE IF EXISTS trip_events;
