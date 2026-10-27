-- Per-member notification preferences: what one user (user_id) wants to hear
-- about another member (subject_id). A missing row means "everything on".
-- SOS/help/check-in alerts are deliberately NOT represented here: they can
-- never be muted. Quiet hours are minutes after local midnight in tz.
CREATE TABLE IF NOT EXISTS notification_prefs (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    muted       BOOLEAN NOT NULL DEFAULT FALSE,
    arrivals    BOOLEAN NOT NULL DEFAULT TRUE,
    departures  BOOLEAN NOT NULL DEFAULT TRUE,
    low_battery BOOLEAN NOT NULL DEFAULT TRUE,
    driving     BOOLEAN NOT NULL DEFAULT TRUE,
    quiet_start SMALLINT CHECK (quiet_start BETWEEN 0 AND 1439),
    quiet_end   SMALLINT CHECK (quiet_end BETWEEN 0 AND 1439),
    tz          TEXT NOT NULL DEFAULT 'UTC',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, subject_id),
    CHECK (user_id <> subject_id),
    CHECK ((quiet_start IS NULL) = (quiet_end IS NULL)),
    CHECK (quiet_start IS NULL OR quiet_start <> quiet_end)
);
CREATE INDEX IF NOT EXISTS idx_notification_prefs_subject ON notification_prefs (subject_id);
