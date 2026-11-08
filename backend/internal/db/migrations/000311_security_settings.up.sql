-- Admin-tunable sign-in hygiene. client_key ties a sign-in to one app install
-- so signing in again on the same phone replaces the old sign-in instead of
-- stacking a new one.
ALTER TABLE refresh_sessions ADD COLUMN IF NOT EXISTS client_key text;
CREATE INDEX IF NOT EXISTS idx_refresh_sessions_client ON refresh_sessions(user_id, client_key) WHERE client_key IS NOT NULL;
CREATE TABLE IF NOT EXISTS security_settings (
    id                  smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    session_idle_days   integer NOT NULL DEFAULT 14 CHECK (session_idle_days BETWEEN 1 AND 365),
    max_sessions_per_user integer NOT NULL DEFAULT 20 CHECK (max_sessions_per_user BETWEEN 1 AND 500),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
INSERT INTO security_settings (id) VALUES (1) ON CONFLICT DO NOTHING;
