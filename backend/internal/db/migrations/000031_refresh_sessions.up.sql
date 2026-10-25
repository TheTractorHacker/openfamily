-- Refresh token rotation with reuse detection (BSEC-003).
-- One row per issued refresh token (jti). Tokens minted from the same login
-- share family_id. A token is single-use: presenting a used or revoked jti
-- again revokes its whole family.
CREATE TABLE IF NOT EXISTS refresh_sessions (
    jti        text PRIMARY KEY,
    family_id  text NOT NULL,
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    used_at    timestamptz,
    revoked_at timestamptz,
    expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_refresh_sessions_family ON refresh_sessions(family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_sessions_user ON refresh_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_sessions_expires ON refresh_sessions(expires_at);
