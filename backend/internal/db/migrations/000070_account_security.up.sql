-- Account security: TOTP replay guard + recovery codes, admin-issued password
-- reset codes, and per-session metadata for device/session management.

-- Highest TOTP time step (unix/30) already accepted for the user. A code for a
-- step <= this value is a replay and is refused.
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_last_step bigint NOT NULL DEFAULT 0;

-- Single-use recovery codes, stored only as an HMAC.
CREATE TABLE IF NOT EXISTS totp_recovery_codes (
    id         bigserial PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash  text NOT NULL,
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_totp_recovery_user ON totp_recovery_codes(user_id);

-- Admin-issued, single-use, short-lived password reset codes (no email needed).
CREATE TABLE IF NOT EXISTS password_reset_codes (
    id         bigserial PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    issued_by  uuid REFERENCES users(id) ON DELETE SET NULL,
    code_hash  text NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_password_reset_user ON password_reset_codes(user_id);

-- Session metadata lives on the first token of each refresh family
-- (jti = family_id); later rotations only add rows to the family.
ALTER TABLE refresh_sessions ADD COLUMN IF NOT EXISTS user_agent text;
