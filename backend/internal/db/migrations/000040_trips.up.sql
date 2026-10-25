-- Trips: server-side segmentation of location history into movement legs.
-- Derived data (recomputable from `locations`), so rows are keyed for
-- idempotent upserts: one trip per (user_id, started_at).
CREATE TABLE IF NOT EXISTS trips (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id     UUID REFERENCES devices(id) ON DELETE SET NULL,
    family_id     UUID REFERENCES families(id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ NOT NULL,
    distance_m    DOUBLE PRECISION NOT NULL,
    -- Speeds are GPS ESTIMATES in meters per second; speed_source says whether
    -- they are device-reported, derived from distance/time, or a mix.
    max_speed_mps DOUBLE PRECISION NOT NULL,
    avg_speed_mps DOUBLE PRECISION NOT NULL,
    mode          TEXT NOT NULL CHECK (mode IN ('driving', 'walking', 'other')),
    speed_source  TEXT NOT NULL CHECK (speed_source IN ('device_gps', 'derived', 'mixed')),
    start_lat     DOUBLE PRECISION NOT NULL,
    start_lon     DOUBLE PRECISION NOT NULL,
    end_lat       DOUBLE PRECISION NOT NULL,
    end_lon       DOUBLE PRECISION NOT NULL,
    point_count   INTEGER NOT NULL,
    -- Segmentation algorithm version that produced the row.
    version       INTEGER NOT NULL DEFAULT 1,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT trips_user_started_key UNIQUE (user_id, started_at),
    CONSTRAINT trips_time_order CHECK (ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS idx_trips_user_started ON trips (user_id, started_at DESC);

-- Per-user incremental watermark for the background job: locations before
-- processed_until have been segmented. last_point_at is the newest location
-- timestamp seen, so the job can tell whether a user has anything new.
CREATE TABLE IF NOT EXISTS trip_watermarks (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    processed_until TIMESTAMPTZ NOT NULL,
    last_point_at   TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
