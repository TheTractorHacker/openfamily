-- 000410_server_key_across_reset.up.sql
-- 1. An owner key reset no longer has to replace the built-in server key. The
--    owner's NEW root phone may keep the account's server key by signing a
--    key-log entry (action 13, ActServerAttach) in the same transaction as the
--    reset. This table records which phone attached it and which log entry
--    carries the signature.
-- 2. e2ee_device_approved: a server key with an attach row hangs on the phone that
--    attached it, not on the (revoked) phone that first approved it, and its own
--    explicit circle approvals made before the attach no longer count.
-- 3. e2ee_item_guard keeps the owner's "require server processing" (ADR 16.1): a
--    required_server circle refuses non-exempt (not checkin/event/chat) PHONE-line
--    items from a member who has no server lane of their own, with ONE narrow
--    exception for a member who is merely CATCHING UP after the server key was replaced
--    (e2ee_member_catching_up): their stored lane=server pref is signed by their own live
--    phone key, not expired, they are a live member, and it is stale (names another or a
--    revoked server key, or an older SK generation) because of a replacement that the
--    SERVER recorded within the last 72 hours. Never for no pref, lane phone, an expired
--    pref or a revoked approver key, and never after the window. The Go handler repeats
--    the decision with signatures verified (SQL cannot verify signatures).
--
-- Idempotent: safe to run again on a database that applied an earlier 000410.

CREATE TABLE IF NOT EXISTS e2ee_server_attach (
    server_device_id   UUID PRIMARY KEY REFERENCES device_keys(device_id) ON DELETE CASCADE,
    attached_by_device_id UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    log_seq            BIGINT NOT NULL,
    signature          BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- When the SK generation last changed (stamped by the trigger below, so every code path that
-- bumps it is covered). NULL = not recorded: never counts as "recent".
ALTER TABLE circles ADD COLUMN IF NOT EXISTS e2ee_server_gen_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION e2ee_server_gen_stamp() RETURNS trigger AS $$
BEGIN
    NEW.e2ee_server_gen_at := now();
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_server_gen_stamp ON circles;
CREATE TRIGGER trg_e2ee_server_gen_stamp BEFORE UPDATE OF e2ee_server_gen ON circles
    FOR EACH ROW WHEN (NEW.e2ee_server_gen IS DISTINCT FROM OLD.e2ee_server_gen)
    EXECUTE FUNCTION e2ee_server_gen_stamp();

-- The member's stored lane=server pref is stale because the server key was replaced, and that
-- happened within the last 72 hours (measured from the oldest applicable server-side record:
-- e2ee_server_device.set_at for another pinned key, device_keys.revoked_at for a revoked
-- named key, circles.e2ee_server_gen_at for an older SK generation). An unknown time counts
-- as "not recent". Legacy conversions are not covered. See docs/design/PRIVACY_PROCESSING.md 16.1.
CREATE OR REPLACE FUNCTION e2ee_member_catching_up(circ UUID, usr UUID) RETURNS BOOLEAN AS $$
    SELECT COALESCE(bool_or(w.since > now() - interval '72 hours'), FALSE) FROM (
        SELECT LEAST(
                 CASE WHEN pk.device_id IS NOT NULL AND pk.device_id <> p.server_device_id
                      THEN COALESCE(sd.set_at, '-infinity'::timestamptz) END,
                 CASE WHEN nk.revoked_at IS NOT NULL THEN nk.revoked_at END,
                 CASE WHEN p.sk_gen < c.e2ee_server_gen
                      THEN COALESCE(c.e2ee_server_gen_at, '-infinity'::timestamptz) END) AS since
          FROM circles c
          JOIN e2ee_processing_pref p ON p.circle_id = c.id AND p.user_id = usr
          JOIN live_circle_members m ON m.circle_id = c.id AND m.user_id = usr
          JOIN device_keys ak ON ak.device_id = p.approver_device_id AND ak.user_id = usr AND ak.kind = 'device' AND ak.revoked_at IS NULL
          LEFT JOIN e2ee_server_device sd ON TRUE
          LEFT JOIN device_keys pk ON pk.device_id = sd.device_id AND pk.kind = 'server' AND pk.revoked_at IS NULL
          LEFT JOIN device_keys nk ON nk.device_id = p.server_device_id
         WHERE c.id = circ AND c.e2ee_mode = 'private' AND c.server_assist
           AND p.lane = 'server' AND NOT p.legacy
           AND (p.valid_until IS NULL OR p.valid_until > now())) w
$$ LANGUAGE sql STABLE;

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
        IF c.member_opt_out = 'required_server' AND NEW.purpose NOT IN ('checkin', 'event', 'chat')
           AND NOT e2ee_pref_lane_server(NEW.circle_id, u) AND NOT e2ee_member_catching_up(NEW.circle_id, u) THEN
            RAISE EXCEPTION 'e2ee_required_server: this circle requires the server lane' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
