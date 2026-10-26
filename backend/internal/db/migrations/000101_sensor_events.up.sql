-- 000101_sensor_events.up.sql
-- Driving events detected by the phone's motion sensor (see docs/driving.md),
-- stored next to the GPS-derived ones. A sensor event may arrive before its
-- trip exists, so trip_id becomes nullable and the event is linked later by
-- (user_id, started_at). Sensor events are NOT derived data: trip recompute
-- only replaces source = 'gps' rows.
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'gps';
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS device_id uuid REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE trip_events ALTER COLUMN trip_id DROP NOT NULL;
-- phone sensors may have no fix: location is optional for sensor events
ALTER TABLE trip_events ALTER COLUMN lat DROP NOT NULL;
ALTER TABLE trip_events ALTER COLUMN lon DROP NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'trip_events_source_check') THEN
        ALTER TABLE trip_events ADD CONSTRAINT trip_events_source_check
            CHECK (source IN ('gps', 'sensor'));
    END IF;
END $$;

-- Idempotent ingest: a retried upload never double counts.
CREATE UNIQUE INDEX IF NOT EXISTS uq_trip_events_sensor
    ON trip_events (user_id, kind, started_at) WHERE source = 'sensor';
-- Linking sensor events that have no trip yet.
CREATE INDEX IF NOT EXISTS idx_trip_events_unlinked
    ON trip_events (user_id, started_at) WHERE trip_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_trip_events_started ON trip_events (started_at);

ALTER TABLE users ADD COLUMN IF NOT EXISTS driving_sensor_enabled boolean NOT NULL DEFAULT false;

-- The single place where "sensor wins" is decided: a GPS-derived event is
-- hidden when a sensor event of the same user and kind overlaps it within
-- +-4 seconds. GPS rows stay stored; every read and report goes through this
-- view.
CREATE OR REPLACE VIEW trip_events_effective AS
SELECT e.*
FROM trip_events e
WHERE e.source = 'sensor'
   OR NOT EXISTS (
        SELECT 1 FROM trip_events s
        WHERE s.source = 'sensor' AND s.user_id = e.user_id AND s.kind = e.kind
          AND s.started_at <= e.ended_at   + interval '4 seconds'
          AND s.ended_at   >= e.started_at - interval '4 seconds');
