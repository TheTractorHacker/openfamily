-- Check-ins to chosen people, temporary sharing pause, time-limited live shares.
-- Every expiry is enforced on read (expires_at / paused_until > now()); the
-- rows are only garbage-collected opportunistically.

-- One-time "I'm here" check-in with a location and optional note. Retained for
-- a fixed window (expires_at), then no longer served and purged.
CREATE TABLE IF NOT EXISTS checkins (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lat        DOUBLE PRECISION,
    lon        DOUBLE PRECISION,
    note       TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_checkins_user ON checkins (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_checkins_expires ON checkins (expires_at);

CREATE TABLE IF NOT EXISTS checkin_recipients (
    checkin_id   UUID NOT NULL REFERENCES checkins(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (checkin_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_checkin_recipients_user ON checkin_recipients (user_id);

-- Temporary pause of ALL location sharing for a user. Honoured wherever
-- sharing_enabled is (members snapshot, WS broadcast, watch). SOS ignores it.
CREATE TABLE IF NOT EXISTS sharing_pauses (
    user_id      UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    paused_until TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Live location shared with one chosen person until expires_at.
CREATE TABLE IF NOT EXISTS live_shares (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    viewer_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    UNIQUE (owner_id, viewer_id),
    CHECK (owner_id <> viewer_id)
);
CREATE INDEX IF NOT EXISTS idx_live_shares_viewer ON live_shares (viewer_id);
CREATE INDEX IF NOT EXISTS idx_live_shares_expires ON live_shares (expires_at);
