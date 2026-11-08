-- Member defaults (docs/design/PRIVACY_PROCESSING.md section 23). Idempotent.
--
-- Admin-configurable, circle-independent defaults for members of circles that
-- have server assistance on. NULL means "derive from the deployment profile":
-- a home server defaults to the server lane with auto-apply, a cloud or unset
-- profile to the phone lane without auto-apply. These flags are ADVICE read by
-- the apps. They never sign, consent or write a processing pref: only the
-- member's own phone ever puts a lane in the key log.
ALTER TABLE server_profile
    ADD COLUMN IF NOT EXISTS member_default_lane TEXT,
    ADD COLUMN IF NOT EXISTS member_auto_apply   BOOLEAN,
    ADD COLUMN IF NOT EXISTS member_defaults_set_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS member_defaults_set_by UUID REFERENCES users(id) ON DELETE SET NULL;
DO $$ BEGIN
    ALTER TABLE server_profile ADD CONSTRAINT server_profile_member_default_lane_chk
        CHECK (member_default_lane IS NULL OR member_default_lane IN ('server', 'phone'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
