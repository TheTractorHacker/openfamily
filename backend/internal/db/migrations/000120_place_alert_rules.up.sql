-- Tunable place alerts.
-- 1) user_quiet_hours: one optional quiet window per user (minutes after local
--    midnight, wraps past midnight when start > end). Place arrival/departure
--    pushes are held back inside it; emergencies never are. The alert itself is
--    still recorded in history.
-- 2) place_alert_rules: per (viewer, tracked member, place) override of which
--    place events the viewer hears. No row = both.
CREATE TABLE IF NOT EXISTS user_quiet_hours (
    user_id     UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    quiet_start SMALLINT NOT NULL CHECK (quiet_start BETWEEN 0 AND 1439),
    quiet_end   SMALLINT NOT NULL CHECK (quiet_end BETWEEN 0 AND 1439),
    tz          TEXT NOT NULL DEFAULT 'UTC',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (quiet_start <> quiet_end)
);

CREATE TABLE IF NOT EXISTS place_alert_rules (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    place_id   UUID NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    mode       TEXT NOT NULL CHECK (mode IN ('arrivals', 'departures', 'off')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, subject_id, place_id),
    CHECK (user_id <> subject_id)
);
CREATE INDEX IF NOT EXISTS idx_place_alert_rules_subject_place ON place_alert_rules (subject_id, place_id);
