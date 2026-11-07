-- 000220_processing_lanes.down.sql
-- REFUSES to run while lanes data exists: it would silently delete server-line
-- items, relabelled legacy history, prefs (and the converted consents). Turn the
-- policy off, purge the server copies and remove the prefs first.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM e2ee_items WHERE key_line = 'server')
       OR EXISTS (SELECT 1 FROM circle_key_wraps WHERE key_line = 'server')
       OR EXISTS (SELECT 1 FROM e2ee_items WHERE purpose IN ('trip', 'drive', 'week'))
       OR EXISTS (SELECT 1 FROM e2ee_processing_pref)
       OR EXISTS (SELECT 1 FROM circles WHERE server_assist OR server_legacy_epoch_max > 0) THEN
        RAISE EXCEPTION 'refusing to drop processing lanes: server-line data, prefs or an upgraded circle exist; clean them up first';
    END IF;
END $$;

-- Restores the pre-lanes functions (migration 000165). Server-line wraps and
-- items are deleted (they cannot be read without the lanes code); key_line
-- columns are dropped. Lane-server data on the server (plaintext copies) stays.
DROP TRIGGER IF EXISTS trg_e2ee_wrap_guard ON circle_key_wraps;
DROP TRIGGER IF EXISTS trg_e2ee_item_guard ON e2ee_items;
DROP TRIGGER IF EXISTS trg_e2ee_pref_server_lane_changed ON e2ee_processing_pref;
DROP TRIGGER IF EXISTS trg_e2ee_policy_turned_off ON circles;
DROP TRIGGER IF EXISTS trg_e2ee_processing_mode_changed ON circles;
DROP TRIGGER IF EXISTS trg_e2ee_processing_pref_member_removed ON circle_members;
DROP TRIGGER IF EXISTS trg_e2ee_device_kind_immutable ON device_keys;
DROP TRIGGER IF EXISTS trg_e2ee_processing_key_revoked ON device_keys;

CREATE OR REPLACE FUNCTION e2ee_member_removed() RETURNS trigger AS $$
BEGIN
    DELETE FROM circle_key_wraps w
     USING device_keys d
     WHERE w.circle_id = OLD.circle_id AND d.device_id = w.recipient_device_id AND d.user_id = OLD.user_id;
    UPDATE circles SET e2ee_rekey_required = TRUE, e2ee_updated_at = now()
     WHERE id = OLD.circle_id AND e2ee_mode = 'private';
    RETURN OLD;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION e2ee_device_revoked() RETURNS trigger AS $$
BEGIN
    IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
        DELETE FROM circle_key_wraps WHERE recipient_device_id = NEW.device_id;
        UPDATE circles SET e2ee_rekey_required = TRUE, e2ee_updated_at = now()
         WHERE e2ee_mode = 'private'
           AND id IN (SELECT circle_id FROM circle_members WHERE user_id = NEW.user_id);
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

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
           AND NOT c.e2ee_rekey_required
           AND NOT EXISTS (
                SELECT 1 FROM live_circle_members m
                 WHERE m.circle_id = c.id
                   AND NOT EXISTS (
                        SELECT 1 FROM e2ee_server_consents sc
                          JOIN device_keys ak ON ak.device_id = sc.approver_device_id
                                              AND ak.user_id = m.user_id AND ak.kind = 'device' AND ak.revoked_at IS NULL
                         WHERE sc.circle_id = c.id AND sc.user_id = m.user_id AND sc.server_device_id = d.device_id))
    )
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION e2ee_plaintext_blocked(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM circles WHERE id = circ AND e2ee_mode = 'private') AND NOT e2ee_server_member(circ)
$$ LANGUAGE sql STABLE;

DROP FUNCTION IF EXISTS e2ee_keeps_data_on_phone(UUID);
DROP FUNCTION IF EXISTS e2ee_purge_user_server_copies(UUID, UUID);
DROP FUNCTION IF EXISTS e2ee_processing_key_revoked();
DROP FUNCTION IF EXISTS e2ee_member_plaintext_ok(UUID, UUID);
DROP FUNCTION IF EXISTS e2ee_member_server_ok(UUID, UUID);
DROP FUNCTION IF EXISTS e2ee_server_assist(UUID);
DROP FUNCTION IF EXISTS e2ee_pref_lane_server(UUID, UUID);
DROP FUNCTION IF EXISTS e2ee_server_member_legacy(UUID);
DROP FUNCTION IF EXISTS e2ee_wrap_guard();
DROP FUNCTION IF EXISTS e2ee_device_kind_immutable();
DROP FUNCTION IF EXISTS e2ee_item_guard();
DROP FUNCTION IF EXISTS e2ee_pref_server_lane_changed();
DROP FUNCTION IF EXISTS e2ee_policy_turned_off();
DROP FUNCTION IF EXISTS e2ee_processing_mode_changed();
DROP FUNCTION IF EXISTS e2ee_processing_pref_member_removed();

DROP INDEX IF EXISTS uq_e2ee_processing_statements_nonce;
DROP TABLE IF EXISTS e2ee_processing_statements;
DROP TABLE IF EXISTS e2ee_processing_pref;

DELETE FROM circle_key_wraps WHERE key_line = 'server';
DELETE FROM e2ee_items WHERE key_line = 'server';
ALTER TABLE circle_key_wraps DROP CONSTRAINT IF EXISTS circle_key_wraps_pkey;
ALTER TABLE circle_key_wraps ADD CONSTRAINT circle_key_wraps_pkey PRIMARY KEY (circle_id, epoch, recipient_device_id);
ALTER TABLE circle_key_wraps DROP CONSTRAINT IF EXISTS circle_key_wraps_key_line_chk;
ALTER TABLE circle_key_wraps DROP COLUMN IF EXISTS key_line;
DROP INDEX IF EXISTS e2ee_items_circle_line;
ALTER TABLE e2ee_items DROP CONSTRAINT IF EXISTS e2ee_items_purpose_check;
ALTER TABLE e2ee_items ADD CONSTRAINT e2ee_items_purpose_check CHECK (purpose IN ('fix', 'event', 'place', 'history', 'checkin', 'chat'));
ALTER TABLE e2ee_items DROP CONSTRAINT IF EXISTS e2ee_items_key_line_chk;
ALTER TABLE e2ee_items DROP COLUMN IF EXISTS key_line;
ALTER TABLE device_keys DROP COLUMN IF EXISTS caps;

ALTER TABLE circles DROP CONSTRAINT IF EXISTS circles_required_server_needs_assist_chk;
ALTER TABLE circles DROP CONSTRAINT IF EXISTS circles_member_opt_out_chk;
ALTER TABLE circles DROP CONSTRAINT IF EXISTS circles_server_assist_default_chk;
ALTER TABLE circles DROP CONSTRAINT IF EXISTS circles_server_gen_chk;
ALTER TABLE circles
    DROP COLUMN IF EXISTS server_assist,
    DROP COLUMN IF EXISTS server_assist_default,
    DROP COLUMN IF EXISTS member_opt_out,
    DROP COLUMN IF EXISTS e2ee_server_gen,
    DROP COLUMN IF EXISTS e2ee_server_commitment,
    DROP COLUMN IF EXISTS e2ee_server_rekey_required,
    DROP COLUMN IF EXISTS server_legacy_ck,
    DROP COLUMN IF EXISTS server_legacy_epoch_max;
