-- 000061_invite_codes_circle.down.sql
-- Circle-only codes cannot exist without circle_id, so they are removed.
DELETE FROM invite_codes WHERE family_id IS NULL;
ALTER TABLE invite_codes DROP CONSTRAINT IF EXISTS invite_codes_target_chk;
DROP INDEX IF EXISTS idx_invite_codes_circle;
ALTER TABLE invite_codes DROP COLUMN IF EXISTS circle_id;
ALTER TABLE invite_codes ALTER COLUMN family_id SET NOT NULL;
