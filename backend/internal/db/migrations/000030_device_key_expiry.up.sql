-- Server-side expiry for per-device ingest keys (BSEC-004 / MOB-003).
-- NULL means a legacy key issued before expiry existed; the API stamps an
-- expiry the first time such a key is used, so active installs keep working
-- while abandoned or leaked-and-unused keys age out.
ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS ingest_key_expires_at timestamptz;
