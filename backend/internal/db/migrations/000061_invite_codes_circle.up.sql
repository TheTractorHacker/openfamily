-- 000061_invite_codes_circle.up.sql
-- Per-circle invitations reuse invite_codes. circle_id names the circle the
-- code joins; family_id is kept (and set) for codes of family-backed circles so
-- the legacy join/register flow behaves exactly as before. A code for a circle
-- that is not a family has family_id NULL and can only be redeemed through
-- POST /circles/join.
ALTER TABLE invite_codes ADD COLUMN IF NOT EXISTS circle_id UUID REFERENCES circles(id) ON DELETE CASCADE;
ALTER TABLE invite_codes ALTER COLUMN family_id DROP NOT NULL;
UPDATE invite_codes SET circle_id = family_id WHERE circle_id IS NULL AND family_id IS NOT NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invite_codes_target_chk') THEN
        ALTER TABLE invite_codes ADD CONSTRAINT invite_codes_target_chk
            CHECK (family_id IS NOT NULL OR circle_id IS NOT NULL);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_invite_codes_circle ON invite_codes (circle_id);
