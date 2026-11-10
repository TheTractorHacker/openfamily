-- 000410_server_key_across_reset.up.sql
-- 1. An owner key reset no longer has to replace the built-in server key. The
--    owner's NEW root phone may keep the account's server key by signing a
--    key-log entry (action 13, ActServerAttach) in the same transaction as the
--    reset. This table records which phone attached it and which log entry
--    carries the signature.
-- 2. e2ee_device_approved: a server key with an attach row hangs on the phone that
--    attached it, not on the (revoked) phone that first approved it, and its own
--    explicit circle approvals made before the attach no longer count.
-- 3. e2ee_item_guard: a member of a required_server circle who is still catching up
--    (no verified server lane yet) may send on the PHONE line. Those items are
--    ciphertext the server cannot read; refusing them left the family with no
--    delivery at all. Enforcement of the owner's choice is that the server only
--    ever ingests members whose OWN signed lane is server.

CREATE TABLE IF NOT EXISTS e2ee_server_attach (
    server_device_id   UUID PRIMARY KEY REFERENCES device_keys(device_id) ON DELETE CASCADE,
    attached_by_device_id UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    log_seq            BIGINT NOT NULL,
    signature          BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION e2ee_device_approved(dev UUID, circ UUID) RETURNS BOOLEAN AS $$
    WITH RECURSIVE chain(device_id, parent, initial, att_at, depth) AS (
        SELECT d.device_id, COALESCE(sa.attached_by_device_id, d.registered_by_device_id), d.initial, sa.created_at, 0
          FROM device_keys d
          LEFT JOIN e2ee_server_attach sa ON sa.server_device_id = d.device_id
         WHERE d.device_id = dev
        UNION
        SELECT k.device_id, COALESCE(sa.attached_by_device_id, k.registered_by_device_id), k.initial, sa.created_at, c.depth + 1
          FROM chain c
          JOIN device_keys k ON k.device_id = c.parent AND c.parent <> c.device_id
          LEFT JOIN e2ee_server_attach sa ON sa.server_device_id = k.device_id
         WHERE c.depth < 32
    )
    SELECT COALESCE(bool_or(
        c.initial OR EXISTS (SELECT 1 FROM device_approvals a
                              WHERE a.device_id = c.device_id AND a.circle_id = circ
                                AND (c.att_at IS NULL OR a.created_at > c.att_at))
    ), FALSE) FROM chain c
$$ LANGUAGE sql STABLE;

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
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
