-- 000165_e2ee_server_member.up.sql
-- End-to-end encryption, "trusted server member" mode (docs/design/E2EE.md,
-- section "Trusted-server mode"). The instance owner may make the OpenFamily
-- server an APPROVED MEMBER DEVICE of a Private circle so the server can read
-- it again (admin map, history, Dawarich sync, geofencing). Nothing here turns
-- that on by itself: a circle is a "server member" circle only while ALL of the
-- following hold, derived in e2ee_server_member() and never stored as a toggle:
--   * a device of kind 'server' is pinned as THE server device (only the server
--     process, holding the ingest token, can pin it);
--   * that key is active and approved (its registration was cross-signed by a
--     phone key of its owner) and holds a wrap of the circle's CURRENT epoch
--     (only a phone can produce a wrap);
--   * every live member that has an active phone key signed an explicit consent
--     naming this circle and this server key (e2ee_server_consents).
-- Revoking the key deletes its wraps (existing trigger), withdrawing any consent
-- or removing a member changes the answer immediately. Idempotent.

ALTER TABLE device_keys DROP CONSTRAINT IF EXISTS device_keys_kind_check;
DO $$ BEGIN
    ALTER TABLE device_keys ADD CONSTRAINT device_keys_kind_check
        CHECK (kind IN ('device', 'recovery', 'web', 'service', 'server'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The one pinned server device (singleton row).
CREATE TABLE IF NOT EXISTS e2ee_server_device (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    device_id UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    set_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-member, per-circle consent, signed by a phone key of that member over
-- "OFE2EE1-SERVERCONSENT\0" || circle || user || server device || fingerprint.
CREATE TABLE IF NOT EXISTS e2ee_server_consents (
    circle_id          UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    server_device_id   UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    approver_device_id UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    signature          BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (circle_id, user_id, server_device_id)
);
CREATE INDEX IF NOT EXISTS idx_e2ee_server_consents_server ON e2ee_server_consents (server_device_id);

-- A member who leaves loses their consent record (a rejoin must consent again).
CREATE OR REPLACE FUNCTION e2ee_server_consent_member_removed() RETURNS trigger AS $$
BEGIN
    DELETE FROM e2ee_server_consents WHERE circle_id = OLD.circle_id AND user_id = OLD.user_id;
    RETURN OLD;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_server_consent_member_removed ON circle_members;
CREATE TRIGGER trg_e2ee_server_consent_member_removed AFTER DELETE ON circle_members
    FOR EACH ROW EXECUTE FUNCTION e2ee_server_consent_member_removed();

-- Switching a circle back to normal (or on again) ends every consent: a later
-- re-enable starts from "nobody allowed the server".
CREATE OR REPLACE FUNCTION e2ee_server_consent_mode_changed() RETURNS trigger AS $$
BEGIN
    DELETE FROM e2ee_server_consents WHERE circle_id = NEW.id;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_server_consent_mode_changed ON circles;
CREATE TRIGGER trg_e2ee_server_consent_mode_changed AFTER UPDATE OF e2ee_mode ON circles
    FOR EACH ROW WHEN (OLD.e2ee_mode IS DISTINCT FROM NEW.e2ee_mode)
    EXECUTE FUNCTION e2ee_server_consent_mode_changed();

-- Does a consent still count? Its phone key must be an active phone key of the
-- same user. (Signature validity is checked in Go on insert and again at ingest.)
CREATE OR REPLACE FUNCTION e2ee_server_member(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1
          FROM circles c
          JOIN e2ee_server_device sd ON TRUE
          JOIN device_keys d ON d.device_id = sd.device_id AND d.kind = 'server' AND d.revoked_at IS NULL
         WHERE c.id = circ AND c.e2ee_mode = 'private' AND c.e2ee_epoch >= 1
           AND EXISTS (SELECT 1 FROM circle_key_wraps w
                        WHERE w.circle_id = c.id AND w.epoch = c.e2ee_epoch AND w.recipient_device_id = d.device_id)
           AND e2ee_device_approved(d.device_id, c.id)
           AND EXISTS (SELECT 1 FROM live_circle_members om WHERE om.circle_id = c.id AND om.user_id = d.user_id)
           AND EXISTS (SELECT 1 FROM live_circle_members m JOIN device_keys k ON k.user_id = m.user_id
                        WHERE m.circle_id = c.id AND k.kind = 'device' AND k.revoked_at IS NULL)
           AND NOT EXISTS (
                SELECT 1 FROM live_circle_members m
                 WHERE m.circle_id = c.id
                   AND EXISTS (SELECT 1 FROM device_keys k WHERE k.user_id = m.user_id AND k.kind = 'device' AND k.revoked_at IS NULL)
                   AND NOT EXISTS (
                        SELECT 1 FROM e2ee_server_consents sc
                          JOIN device_keys ak ON ak.device_id = sc.approver_device_id
                                              AND ak.user_id = m.user_id AND ak.kind = 'device' AND ak.revoked_at IS NULL
                         WHERE sc.circle_id = c.id AND sc.user_id = m.user_id AND sc.server_device_id = d.device_id))
    )
$$ LANGUAGE sql STABLE;

-- The phase-2 plaintext ban applies to private circles that have NO approved
-- server member. Everything that used `e2ee_mode = 'private'` as the ban uses this.
CREATE OR REPLACE FUNCTION e2ee_plaintext_blocked(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM circles WHERE id = circ AND e2ee_mode = 'private') AND NOT e2ee_server_member(circ)
$$ LANGUAGE sql STABLE;

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
    IF target IS NOT NULL AND e2ee_plaintext_blocked(target) THEN
        RAISE EXCEPTION 'e2ee_private_circle: plaintext location data is not stored for a private circle'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Provenance of server-decrypted positions, so that "purge" can remove exactly them.
ALTER TABLE locations ADD COLUMN IF NOT EXISTS e2ee_circle_id UUID;
CREATE INDEX IF NOT EXISTS idx_locations_e2ee_circle ON locations (e2ee_circle_id, ts) WHERE e2ee_circle_id IS NOT NULL;
