DROP VIEW IF EXISTS trip_events_effective;
DROP VIEW IF EXISTS trip_events_visible;
DROP TABLE IF EXISTS trip_passenger_marks;
ALTER TABLE trip_events DROP COLUMN IF EXISTS max_speed_mps;
ALTER TABLE trip_events DROP COLUMN IF EXISTS confidence;
ALTER TABLE trip_events DROP COLUMN IF EXISTS activity;
ALTER TABLE trip_events DROP COLUMN IF EXISTS dismissed_at;
CREATE OR REPLACE VIEW trip_events_effective AS
SELECT e.*
FROM trip_events e
WHERE e.source = 'sensor'
   OR NOT EXISTS (
        SELECT 1 FROM trip_events s
        WHERE s.source = 'sensor' AND s.user_id = e.user_id AND s.kind = e.kind
          AND s.started_at BETWEEN e.started_at - interval '4 seconds'
                               AND e.started_at + interval '4 seconds');
