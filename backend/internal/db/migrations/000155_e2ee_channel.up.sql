-- 000155_e2ee_channel.up.sql
-- End-to-end encryption, phase 2 (docs/design/E2EE.md): the encrypted channel.
--
-- e2ee_items holds CIPHERTEXT ONLY, addressed to a circle in e2ee_mode='private'.
-- There is no column that could hold a coordinate, a place name or a user-visible
-- timestamp finer than the coarse receive time. Idempotent.

-- Device kinds: a phone ('device'), the recovery identity ('recovery'), a
-- browser viewer ('web') and a bridge service such as Dawarich ('service').
-- web/service keys are ordinary approved circle members' keys (they go through
-- the same cross-signature / admin-approval chain) and can_upload is FALSE
-- unless the registration asked for it.
ALTER TABLE device_keys DROP CONSTRAINT IF EXISTS device_keys_kind_check;
DO $$ BEGIN
    ALTER TABLE device_keys ADD CONSTRAINT device_keys_kind_check
        CHECK (kind IN ('device', 'recovery', 'web', 'service'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE device_keys ADD COLUMN IF NOT EXISTS can_upload BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE device_keys SET can_upload = TRUE WHERE kind = 'device' AND can_upload = FALSE;

CREATE TABLE IF NOT EXISTS e2ee_items (
    -- Cursor. Inserts for one circle are serialised by an advisory lock, so ids
    -- of one circle become visible in increasing order (no skipped ids).
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    circle_id   UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    device_id   UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    -- Per (circle, device) sender sequence number; the idempotency key.
    seq         BIGINT NOT NULL CHECK (seq > 0 AND seq < 9007199254740992),
    purpose     TEXT NOT NULL CHECK (purpose IN ('fix', 'event', 'place', 'history', 'checkin', 'chat')),
    epoch       INTEGER NOT NULL CHECK (epoch >= 1),
    -- padded plaintext length (a Pad bucket); ciphertext length is derived from it
    size_bucket INTEGER NOT NULL CHECK (size_bucket >= 256),
    ciphertext  BYTEA NOT NULL,
    -- Coarse receive time (truncated to the minute): not a precise movement clock.
    received_at TIMESTAMPTZ NOT NULL,
    expires_at  TIMESTAMPTZ,
    UNIQUE (circle_id, device_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_e2ee_items_circle_id ON e2ee_items (circle_id, id);
CREATE INDEX IF NOT EXISTS idx_e2ee_items_circle_purpose ON e2ee_items (circle_id, purpose, id);
CREATE INDEX IF NOT EXISTS idx_e2ee_items_device ON e2ee_items (device_id);
CREATE INDEX IF NOT EXISTS idx_e2ee_items_expires ON e2ee_items (expires_at) WHERE expires_at IS NOT NULL;

-- Downgrade protection in the database itself: a plaintext place, geofence or
-- bubble can never be written for a circle in private mode, whatever code path
-- tries it. (DELETE stays allowed so an admin can clear old plaintext.)
CREATE OR REPLACE FUNCTION e2ee_refuse_plaintext() RETURNS trigger AS $$
DECLARE
    target UUID;
BEGIN
    IF TG_TABLE_NAME = 'places' THEN
        target := COALESCE(NEW.circle_id, NEW.family_id);
    ELSIF TG_TABLE_NAME = 'geofences' THEN
        target := NEW.family_id;
    ELSE
        target := NEW.circle_id;
    END IF;
    IF target IS NOT NULL AND EXISTS (SELECT 1 FROM circles WHERE id = target AND e2ee_mode = 'private') THEN
        RAISE EXCEPTION 'e2ee_private_circle: plaintext location data is not stored for a private circle'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_e2ee_places ON places;
CREATE TRIGGER trg_e2ee_places BEFORE INSERT OR UPDATE ON places
    FOR EACH ROW EXECUTE FUNCTION e2ee_refuse_plaintext();
DROP TRIGGER IF EXISTS trg_e2ee_geofences ON geofences;
CREATE TRIGGER trg_e2ee_geofences BEFORE INSERT OR UPDATE ON geofences
    FOR EACH ROW EXECUTE FUNCTION e2ee_refuse_plaintext();
DROP TRIGGER IF EXISTS trg_e2ee_bubbles ON bubbles;
CREATE TRIGGER trg_e2ee_bubbles BEFORE INSERT OR UPDATE ON bubbles
    FOR EACH ROW EXECUTE FUNCTION e2ee_refuse_plaintext();
