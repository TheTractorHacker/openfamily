-- Bubbles: a temporary, per-person geofence. The creator is alerted when the
-- subject leaves (and optionally re-enters) a circle drawn around the place the
-- subject was when the Bubble was created. Rows are deleted once expires_at has
-- passed (reads ignore them earlier). last_inside is the evaluation state.
CREATE TABLE IF NOT EXISTS bubbles (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    circle_id     UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    creator_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lat           DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lon           DOUBLE PRECISION NOT NULL CHECK (lon BETWEEN -180 AND 180),
    radius_m      INTEGER NOT NULL CHECK (radius_m BETWEEN 50 AND 5000),
    notify_reenter BOOLEAN NOT NULL DEFAULT FALSE,
    expires_at    TIMESTAMPTZ NOT NULL,
    last_inside   BOOLEAN NOT NULL DEFAULT TRUE,
    last_event_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (creator_id <> subject_id)
);
CREATE INDEX IF NOT EXISTS idx_bubbles_subject ON bubbles (subject_id);
CREATE INDEX IF NOT EXISTS idx_bubbles_creator ON bubbles (creator_id);
CREATE INDEX IF NOT EXISTS idx_bubbles_expires ON bubbles (expires_at);
