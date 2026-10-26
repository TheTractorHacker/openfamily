-- 000103: phone-use detection is a separate, off-by-default opt-in from the
-- motion sensor. Until a client says otherwise the server reports phone_use
-- as null (unknown) rather than 0 and rejects phone_use events.
ALTER TABLE users ADD COLUMN IF NOT EXISTS driving_phone_use_enabled boolean NOT NULL DEFAULT false;
