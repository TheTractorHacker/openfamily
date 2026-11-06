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
DROP INDEX IF EXISTS idx_locations_e2ee_circle;
DELETE FROM locations WHERE e2ee_circle_id IS NOT NULL;
ALTER TABLE locations DROP COLUMN IF EXISTS e2ee_circle_id;
DROP TRIGGER IF EXISTS trg_e2ee_server_consent_mode_changed ON circles;
DROP FUNCTION IF EXISTS e2ee_server_consent_mode_changed();
DROP TRIGGER IF EXISTS trg_e2ee_server_consent_member_removed ON circle_members;
DROP FUNCTION IF EXISTS e2ee_server_consent_member_removed();
DROP FUNCTION IF EXISTS e2ee_plaintext_blocked(UUID);
DROP FUNCTION IF EXISTS e2ee_server_member(UUID);
DROP TABLE IF EXISTS e2ee_server_consents;
DROP TABLE IF EXISTS e2ee_server_device;
DELETE FROM device_keys WHERE kind = 'server';
ALTER TABLE device_keys DROP CONSTRAINT IF EXISTS device_keys_kind_check;
ALTER TABLE device_keys ADD CONSTRAINT device_keys_kind_check CHECK (kind IN ('device', 'recovery', 'web', 'service'));
