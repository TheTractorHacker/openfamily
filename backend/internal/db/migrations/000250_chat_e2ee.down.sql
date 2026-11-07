-- 000250_chat_e2ee.down.sql
-- Restores the 000220 item guard. Encrypted blobs are deleted (they cannot be
-- read without the app code that holds their keys).
DROP TABLE IF EXISTS e2ee_blobs;
ALTER TABLE chat_reads DROP COLUMN IF EXISTS e2ee_item_id;
DROP TRIGGER IF EXISTS trg_chat_plaintext_guard ON chat_messages;
DROP FUNCTION IF EXISTS chat_plaintext_guard();
ALTER TABLE e2ee_items DROP CONSTRAINT IF EXISTS e2ee_items_chat_phone_only;
CREATE OR REPLACE FUNCTION e2ee_item_guard() RETURNS trigger AS $$
DECLARE
    c circles%ROWTYPE;
    u UUID;
BEGIN
    SELECT * INTO c FROM circles WHERE id = NEW.circle_id;
    SELECT user_id INTO u FROM device_keys WHERE device_id = NEW.device_id;
    IF NEW.key_line = 'server' THEN
        IF NOT (c.e2ee_mode = 'private' AND c.server_assist AND e2ee_pref_lane_server(NEW.circle_id, u)) THEN
            RAISE EXCEPTION 'e2ee_lane: a server-line item needs server assistance and an author in lane server'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF c.server_legacy_epoch_max > 0 AND NEW.epoch <= c.server_legacy_epoch_max THEN
            RAISE EXCEPTION 'e2ee_legacy_epoch_closed: this key epoch is closed' USING ERRCODE = 'check_violation';
        END IF;
        IF c.member_opt_out = 'required_server' AND NEW.purpose NOT IN ('checkin', 'event') AND NOT e2ee_pref_lane_server(NEW.circle_id, u) THEN
            RAISE EXCEPTION 'e2ee_required_server: this circle requires the server lane' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
