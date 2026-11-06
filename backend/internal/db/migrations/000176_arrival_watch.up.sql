-- 000176_arrival_watch.up.sql
-- Missed-arrival alerts ("usually home by 4, not yet"). Strictly opt-in per
-- member and place, and only evaluated for circles whose positions the server
-- can read (plaintext or trusted-server circles). Idempotent.
CREATE TABLE IF NOT EXISTS arrival_watch (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    place_id   UUID NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    tz         TEXT NOT NULL DEFAULT 'UTC',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, place_id)
);

-- One row per alert sent: the unique key makes a day's alert idempotent and the
-- table is the source for the hard rate limit.
CREATE TABLE IF NOT EXISTS arrival_alert_log (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    place_id   UUID NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    day        DATE NOT NULL,
    alerted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, place_id, day)
);
