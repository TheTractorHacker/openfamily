ALTER TABLE server_profile DROP CONSTRAINT IF EXISTS server_profile_member_default_lane_chk;
ALTER TABLE server_profile
    DROP COLUMN IF EXISTS member_default_lane,
    DROP COLUMN IF EXISTS member_auto_apply,
    DROP COLUMN IF EXISTS member_defaults_set_at,
    DROP COLUMN IF EXISTS member_defaults_set_by;
