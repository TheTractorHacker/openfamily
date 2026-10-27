DROP INDEX IF EXISTS idx_refresh_sessions_parent;
ALTER TABLE refresh_sessions DROP COLUMN IF EXISTS grace_used_at;
ALTER TABLE refresh_sessions DROP COLUMN IF EXISTS parent_jti;
