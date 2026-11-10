-- 000410_server_key_across_reset.down.sql
CREATE OR REPLACE FUNCTION e2ee_item_guard() RETURNS trigger AS $$
DECLARE
    c circles%ROWTYPE;
    u UUID;
BEGIN
    SELECT * INTO c FROM circles WHERE id = NEW.circle_id;
    SELECT user_id INTO u FROM device_keys WHERE device_id = NEW.device_id;
    IF NEW.purpose = 'chat' AND NEW.key_line <> 'phone' THEN
        RAISE EXCEPTION 'e2ee_chat_phone_only: chat is sealed under the phone key only'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.key_line = 'server' THEN
        IF NOT (c.e2ee_mode = 'private' AND c.server_assist AND e2ee_pref_lane_server(NEW.circle_id, u)) THEN
            RAISE EXCEPTION 'e2ee_lane: a server-line item needs server assistance and an author in lane server'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF c.server_legacy_epoch_max > 0 AND NEW.epoch <= c.server_legacy_epoch_max THEN
            RAISE EXCEPTION 'e2ee_legacy_epoch_closed: this key epoch is closed' USING ERRCODE = 'check_violation';
        END IF;
        IF c.member_opt_out = 'required_server' AND NEW.purpose NOT IN ('checkin', 'event', 'chat') AND NOT e2ee_pref_lane_server(NEW.circle_id, u) THEN
            RAISE EXCEPTION 'e2ee_required_server: this circle requires the server lane' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION e2ee_device_approved(dev UUID, circ UUID) RETURNS BOOLEAN AS $$
    WITH RECURSIVE chain(device_id, parent, initial, depth) AS (
        SELECT device_id, registered_by_device_id, initial, 0
          FROM device_keys WHERE device_id = dev
        UNION
        SELECT k.device_id, k.registered_by_device_id, k.initial, c.depth + 1
          FROM chain c
          JOIN device_keys k ON k.device_id = c.parent AND c.parent <> c.device_id
         WHERE c.depth < 32
    )
    SELECT COALESCE(bool_or(
        c.initial OR EXISTS (SELECT 1 FROM device_approvals a
                              WHERE a.device_id = c.device_id AND a.circle_id = circ)
    ), FALSE) FROM chain c
$$ LANGUAGE sql STABLE;

DROP TABLE IF EXISTS e2ee_server_attach;
