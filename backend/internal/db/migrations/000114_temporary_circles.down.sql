DROP VIEW IF EXISTS live_circle_members;
DROP INDEX IF EXISTS idx_circles_ended;
DROP INDEX IF EXISTS idx_circles_expires;
ALTER TABLE circles DROP COLUMN IF EXISTS ended_at;
ALTER TABLE circles DROP COLUMN IF EXISTS expires_at;
