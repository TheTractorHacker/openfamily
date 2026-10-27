-- Lost-response grace for refresh rotation: a spent refresh token may be
-- re-presented once, within a short window, if the token its rotation produced
-- was never used. parent_jti links a token to the one it replaced;
-- grace_used_at makes the retry single-use per spent token.
ALTER TABLE refresh_sessions ADD COLUMN IF NOT EXISTS parent_jti text;
ALTER TABLE refresh_sessions ADD COLUMN IF NOT EXISTS grace_used_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_refresh_sessions_parent ON refresh_sessions(parent_jti) WHERE parent_jti IS NOT NULL;
