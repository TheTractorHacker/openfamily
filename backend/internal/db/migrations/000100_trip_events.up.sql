-- 000100_trip_events.up.sql
-- Driving risk events detected from GPS inside a driving trip (see
-- docs/driving.md). Derived data: recomputed together with the trip, so the
-- rows are replaced, never appended to. Estimates only; as sensitive as trips.
CREATE TABLE IF NOT EXISTS trip_events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id    UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at   TIMESTAMPTZ NOT NULL,
    -- max speed in m/s for speeding, acceleration magnitude in m/s^2 otherwise
    magnitude  DOUBLE PRECISION NOT NULL,
    lat        DOUBLE PRECISION NOT NULL,
    lon        DOUBLE PRECISION NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'trip_events_kind_check') THEN
        ALTER TABLE trip_events ADD CONSTRAINT trip_events_kind_check
            CHECK (kind IN ('speeding', 'hard_brake', 'rapid_accel', 'phone_use'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_trip_events_user_started ON trip_events (user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_trip_events_trip ON trip_events (trip_id);
