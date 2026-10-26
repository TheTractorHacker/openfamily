CREATE OR REPLACE VIEW trip_events_effective AS
SELECT e.*
FROM trip_events e
WHERE e.source = 'sensor'
   OR NOT EXISTS (
        SELECT 1 FROM trip_events s
        WHERE s.source = 'sensor' AND s.user_id = e.user_id AND s.kind = e.kind
          AND s.started_at <= e.ended_at   + interval '4 seconds'
          AND s.ended_at   >= e.started_at - interval '4 seconds');
