-- 000102: tighten the "sensor wins" rule.
-- 000101 hid a GPS-derived event whenever a sensor event of the same kind
-- overlapped its time interval by +-4 s. Combined with a long sensor event
-- that let one self-reported event hide many real ones. A GPS event is now
-- hidden only by a sensor event whose START is within 4 s of the GPS event's
-- start (a point match), and ingest limits braking/acceleration events to 10 s.
CREATE OR REPLACE VIEW trip_events_effective AS
SELECT e.*
FROM trip_events e
WHERE e.source = 'sensor'
   OR NOT EXISTS (
        SELECT 1 FROM trip_events s
        WHERE s.source = 'sensor' AND s.user_id = e.user_id AND s.kind = e.kind
          AND s.started_at BETWEEN e.started_at - interval '4 seconds'
                               AND e.started_at + interval '4 seconds');
