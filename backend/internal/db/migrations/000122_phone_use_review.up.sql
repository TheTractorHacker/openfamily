-- 000122: phone-use review.
--  * Optional detail on sensor events: peak speed, confidence (0..1) and the
--    activity (screen / call). Old clients simply leave them NULL.
--  * dismissed_at: the owner marked a phone_use event as a false alarm.
--  * trip_passenger_marks: the owner marked a whole drive "I was a passenger".
--    Keyed by (user_id, started_at) because trips are recomputed (deleted and
--    re-inserted) while the start time stays stable.
-- trip_events_visible is the old "sensor wins" view (owner sees dismissed
-- rows there so they can be undone); trip_events_effective, which every
-- report and score reads, additionally hides dismissed events and the events
-- of passenger drives.
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS max_speed_mps double precision;
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS confidence real;
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS activity text;
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS dismissed_at timestamptz;

CREATE TABLE IF NOT EXISTS trip_passenger_marks (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ NOT NULL,
    marked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, started_at)
);

CREATE OR REPLACE VIEW trip_events_visible AS
SELECT e.*
FROM trip_events e
WHERE e.source = 'sensor'
   OR NOT EXISTS (
        SELECT 1 FROM trip_events s
        WHERE s.source = 'sensor' AND s.user_id = e.user_id AND s.kind = e.kind
          AND s.started_at BETWEEN e.started_at - interval '4 seconds'
                               AND e.started_at + interval '4 seconds');

CREATE OR REPLACE VIEW trip_events_effective AS
SELECT v.*
FROM trip_events_visible v
WHERE v.dismissed_at IS NULL
  AND NOT EXISTS (
        SELECT 1 FROM trips t
        JOIN trip_passenger_marks m ON m.user_id = t.user_id AND m.started_at = t.started_at
        WHERE t.id = v.trip_id);
