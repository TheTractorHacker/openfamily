-- Per (viewer, tracked member) master switch for place arrival/departure
-- pushes. No row = enabled (the default). Only the viewer is affected.
CREATE TABLE IF NOT EXISTS member_place_alerts (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    enabled    BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, subject_id),
    CHECK (user_id <> subject_id)
);
CREATE INDEX IF NOT EXISTS idx_member_place_alerts_subject ON member_place_alerts (subject_id) WHERE enabled = FALSE;
