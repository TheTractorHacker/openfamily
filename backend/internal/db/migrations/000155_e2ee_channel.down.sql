DROP TRIGGER IF EXISTS trg_e2ee_places ON places;
DROP TRIGGER IF EXISTS trg_e2ee_geofences ON geofences;
DROP TRIGGER IF EXISTS trg_e2ee_bubbles ON bubbles;
DROP FUNCTION IF EXISTS e2ee_refuse_plaintext();
DROP TABLE IF EXISTS e2ee_items;
DELETE FROM device_keys WHERE kind IN ('web', 'service');
ALTER TABLE device_keys DROP COLUMN IF EXISTS can_upload;
ALTER TABLE device_keys DROP CONSTRAINT IF EXISTS device_keys_kind_check;
ALTER TABLE device_keys ADD CONSTRAINT device_keys_kind_check CHECK (kind IN ('device', 'recovery'));
