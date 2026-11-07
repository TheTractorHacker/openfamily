-- 000220_processing_lanes.up.sql
-- Per-member privacy lanes (docs/design/PRIVACY_PROCESSING.md, phase 2 server).
--
-- A Private circle has two key lines, both held by all members' phones:
--   * the phone key CK (circle_key_wraps.key_line = 'phone'): NEVER wrapped to a
--     'server'-kind device (trigger below), except in a LEGACY trusted-server
--     circle (server_legacy_ck, set once by this migration for circles that were
--     already in trusted-server mode and cleared by the admin "upgrade" action);
--   * the server key SK (key_line = 'server'): wrapped to the server device only
--     while the admin policy is on AND at least one member signed lane 'server'.
-- A member's lane is their own phone-signed processing_pref. No pref = phone.
-- Nothing here turns server processing on; every flag is mirrored from a signed
-- statement stored in e2ee_processing_statements. Idempotent.

ALTER TABLE circles
    ADD COLUMN IF NOT EXISTS server_assist              BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS server_assist_default      TEXT    NOT NULL DEFAULT 'phone',
    ADD COLUMN IF NOT EXISTS member_opt_out             TEXT    NOT NULL DEFAULT 'allowed',
    ADD COLUMN IF NOT EXISTS e2ee_server_gen           INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS e2ee_server_commitment    BYTEA,
    ADD COLUMN IF NOT EXISTS e2ee_server_rekey_required BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS server_legacy_ck          BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS server_legacy_epoch_max   INTEGER NOT NULL DEFAULT 0;
DO $$ BEGIN
    ALTER TABLE circles ADD CONSTRAINT circles_server_assist_default_chk CHECK (server_assist_default IN ('phone', 'server'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TABLE circles ADD CONSTRAINT circles_member_opt_out_chk CHECK (member_opt_out IN ('allowed', 'required_server'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TABLE circles ADD CONSTRAINT circles_required_server_needs_assist_chk CHECK (member_opt_out = 'allowed' OR server_assist);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TABLE circles ADD CONSTRAINT circles_server_gen_chk CHECK (e2ee_server_gen >= 0 AND server_legacy_epoch_max >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Client capabilities (self-declared, unsigned): {'lanes2'} = the app can read
-- and write v2 items and the server line. An app without it stays phone-only.
ALTER TABLE device_keys ADD COLUMN IF NOT EXISTS caps TEXT[] NOT NULL DEFAULT '{}';

-- Wraps and items carry their key line; existing rows are the phone line.
ALTER TABLE circle_key_wraps ADD COLUMN IF NOT EXISTS key_line TEXT NOT NULL DEFAULT 'phone';
DO $$ BEGIN
    ALTER TABLE circle_key_wraps ADD CONSTRAINT circle_key_wraps_key_line_chk CHECK (key_line IN ('phone', 'server'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- For the server line the "epoch" column holds the SK generation.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
                    WHERE c.conrelid = 'circle_key_wraps'::regclass AND c.contype = 'p' AND a.attname = 'key_line') THEN
        ALTER TABLE circle_key_wraps DROP CONSTRAINT circle_key_wraps_pkey;
        ALTER TABLE circle_key_wraps ADD CONSTRAINT circle_key_wraps_pkey PRIMARY KEY (circle_id, key_line, epoch, recipient_device_id);
    END IF;
END $$;

ALTER TABLE e2ee_items ADD COLUMN IF NOT EXISTS key_line TEXT NOT NULL DEFAULT 'phone';
DO $$ BEGIN
    ALTER TABLE e2ee_items ADD CONSTRAINT e2ee_items_key_line_chk CHECK (key_line IN ('phone', 'server'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS e2ee_items_circle_line ON e2ee_items (circle_id, key_line, id);
-- Phone-computed result items (ADR 8.4): trip, drive, week.
ALTER TABLE e2ee_items DROP CONSTRAINT IF EXISTS e2ee_items_purpose_check;
DO $$ BEGIN
    ALTER TABLE e2ee_items ADD CONSTRAINT e2ee_items_purpose_check
        CHECK (purpose IN ('fix', 'event', 'place', 'history', 'checkin', 'chat', 'trip', 'drive', 'week'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The current preference of each member (no row = phone). legacy = converted
-- from an OFE2EE1-SERVERCONSENT row by the admin upgrade (signature is then the
-- old consent signature and nonce is NULL).
CREATE TABLE IF NOT EXISTS e2ee_processing_pref (
    circle_id          UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lane               TEXT NOT NULL CHECK (lane IN ('phone', 'server')),
    sk_gen             INTEGER NOT NULL DEFAULT 0 CHECK (sk_gen >= 0),
    server_device_id   UUID REFERENCES device_keys(device_id) ON DELETE CASCADE,
    server_fingerprint BYTEA CHECK (server_fingerprint IS NULL OR octet_length(server_fingerprint) = 32),
    nonce              BYTEA CHECK (nonce IS NULL OR octet_length(nonce) = 16),
    approver_device_id UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    signature          BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    legacy             BOOLEAN NOT NULL DEFAULT FALSE,
    log_seq            BIGINT,
    signed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Legacy conversions are valid only for a bounded time after the upgrade; the
    -- member must sign a fresh pref before then. NULL = no expiry (a signed pref).
    valid_until        TIMESTAMPTZ,
    PRIMARY KEY (circle_id, user_id),
    CHECK (lane = 'phone' OR (sk_gen >= 1 AND server_device_id IS NOT NULL))
);

-- Append-only record of every signed processing_pref / processing_policy so
-- phones can verify the history against the log (log_seq).
CREATE TABLE IF NOT EXISTS e2ee_processing_statements (
    log_seq            BIGINT PRIMARY KEY,
    circle_id          UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id            UUID NOT NULL,
    kind               TEXT NOT NULL CHECK (kind IN ('pref', 'policy')),
    lane               TEXT,           -- pref: lane;  policy: 'server' when assist on, else 'phone'
    default_for_new    TEXT,
    member_opt_out     TEXT,
    sk_gen             INTEGER NOT NULL DEFAULT 0,
    server_device_id   UUID,
    server_fingerprint BYTEA,
    commitment         BYTEA,
    nonce              BYTEA,
    actor_device_id    UUID NOT NULL,
    signature          BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_e2ee_processing_statements_circle ON e2ee_processing_statements (circle_id, log_seq);
-- A signed statement can be submitted once: a replayed nonce is refused.
CREATE UNIQUE INDEX IF NOT EXISTS uq_e2ee_processing_statements_nonce ON e2ee_processing_statements (nonce) WHERE nonce IS NOT NULL;

-- ---------------------------------------------------------------- functions

-- The pre-lanes trusted-server rule (migration 000165), restricted to circles
-- still flagged legacy: server holds CK, EVERY live member consented.
CREATE OR REPLACE FUNCTION e2ee_server_member_legacy(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1
          FROM circles c
          JOIN e2ee_server_device sd ON TRUE
          JOIN device_keys d ON d.device_id = sd.device_id AND d.kind = 'server' AND d.revoked_at IS NULL
         WHERE c.id = circ AND c.e2ee_mode = 'private' AND c.e2ee_epoch >= 1 AND c.server_legacy_ck
           AND EXISTS (SELECT 1 FROM circle_key_wraps w
                        WHERE w.circle_id = c.id AND w.key_line = 'phone' AND w.epoch = c.e2ee_epoch AND w.recipient_device_id = d.device_id)
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

-- Does the member hold a (SQL-visible) lane-server preference? Signatures are
-- re-verified in Go wherever plaintext is WRITTEN (ingest, item relay).
CREATE OR REPLACE FUNCTION e2ee_pref_lane_server(circ UUID, usr UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM circles c
          JOIN e2ee_processing_pref p ON p.circle_id = c.id AND p.user_id = usr
          JOIN live_circle_members m ON m.circle_id = c.id AND m.user_id = usr
          JOIN device_keys ak ON ak.device_id = p.approver_device_id AND ak.user_id = usr AND ak.kind = 'device' AND ak.revoked_at IS NULL
          JOIN e2ee_server_device sd ON sd.device_id = p.server_device_id
          JOIN device_keys sk ON sk.device_id = sd.device_id AND sk.kind = 'server' AND sk.revoked_at IS NULL
         WHERE c.id = circ AND c.e2ee_mode = 'private' AND c.server_assist AND p.lane = 'server'
           AND (p.valid_until IS NULL OR p.valid_until > now())
           AND p.sk_gen BETWEEN 1 AND c.e2ee_server_gen)
$$ LANGUAGE sql STABLE;

-- Server assistance is in effect for the circle: policy on, pinned server key
-- active+approved, holding the CURRENT SK generation, no SK rotation pending.
CREATE OR REPLACE FUNCTION e2ee_server_assist(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1
          FROM circles c
          JOIN e2ee_server_device sd ON TRUE
          JOIN device_keys d ON d.device_id = sd.device_id AND d.kind = 'server' AND d.revoked_at IS NULL
         WHERE c.id = circ AND c.e2ee_mode = 'private' AND c.server_assist AND c.e2ee_server_gen >= 1
           AND NOT c.e2ee_server_rekey_required
           AND EXISTS (SELECT 1 FROM circle_key_wraps w
                        WHERE w.circle_id = c.id AND w.key_line = 'server' AND w.epoch = c.e2ee_server_gen AND w.recipient_device_id = d.device_id)
           AND e2ee_device_approved(d.device_id, c.id)
           AND EXISTS (SELECT 1 FROM live_circle_members om WHERE om.circle_id = c.id AND om.user_id = d.user_id)
    )
$$ LANGUAGE sql STABLE;

-- THE per-user gate: may the server hold/read this member's plaintext through
-- this circle? Legacy circle: every member consented (all-or-nothing, old rule).
-- Lanes circle: assistance in effect AND this member's own lane is server.
CREATE OR REPLACE FUNCTION e2ee_member_server_ok(circ UUID, usr UUID) RETURNS BOOLEAN AS $$
    SELECT (e2ee_server_member_legacy(circ)
            AND EXISTS (SELECT 1 FROM live_circle_members WHERE circle_id = circ AND user_id = usr))
        OR (e2ee_pref_lane_server(circ, usr) AND e2ee_server_assist(circ))
$$ LANGUAGE sql STABLE;

-- Plaintext of this member is allowed to exist for this circle: a normal circle,
-- or a private one whose server may read THIS member.
CREATE OR REPLACE FUNCTION e2ee_member_plaintext_ok(circ UUID, usr UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM circles WHERE id = circ AND e2ee_mode = 'off') OR e2ee_member_server_ok(circ, usr)
$$ LANGUAGE sql STABLE;

-- Compatibility: "the server can read at least part of this circle" (the
-- circle-list flag old clients show). NOT an authorization gate any more.
CREATE OR REPLACE FUNCTION e2ee_server_member(circ UUID) RETURNS BOOLEAN AS $$
    SELECT e2ee_server_member_legacy(circ)
        OR (e2ee_server_assist(circ)
            AND EXISTS (SELECT 1 FROM live_circle_members m WHERE m.circle_id = circ AND e2ee_pref_lane_server(circ, m.user_id)))
$$ LANGUAGE sql STABLE;

-- Circle-level plaintext ban (places, geofences, bubbles): a private circle
-- allows server-side places only in a legacy trusted-server circle. In a lanes
-- circle phones evaluate places (E2EE.md "one source of truth").
CREATE OR REPLACE FUNCTION e2ee_plaintext_blocked(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM circles WHERE id = circ AND e2ee_mode = 'private') AND NOT e2ee_server_member_legacy(circ)
$$ LANGUAGE sql STABLE;

-- The member keeps their data on their phone: they sit in at least one live
-- Private circle and the server may read them through none of their circles.
CREATE OR REPLACE FUNCTION e2ee_keeps_data_on_phone(usr UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM live_circle_members km JOIN circles kc ON kc.id = km.circle_id
                    WHERE km.user_id = usr AND kc.e2ee_mode = 'private')
       AND NOT EXISTS (SELECT 1 FROM live_circle_members km WHERE km.user_id = usr AND e2ee_member_plaintext_ok(km.circle_id, km.user_id))
$$ LANGUAGE sql STABLE;

-- Removes the server's plaintext copies of one member that came from one circle:
-- the tagged locations, a last-known position that IS one of those points, and
-- all of the member's own server-line items (they are readable by the server).
CREATE OR REPLACE FUNCTION e2ee_purge_user_server_copies(circ UUID, usr UUID) RETURNS VOID AS $$
DECLARE
    tss TIMESTAMPTZ[];
BEGIN
    -- Serialise with ingest: ingest holds this circle row FOR SHARE for its whole
    -- batch, so a purge waits for an in-flight batch to commit and then removes what
    -- it wrote; an ingest that starts later waits for this transaction and then sees
    -- the member's lane gone. Lock order everywhere: circles (by id) before anything else.
    PERFORM 1 FROM circles WHERE id = circ FOR UPDATE;
    WITH del AS (
        DELETE FROM locations l USING devices d
         WHERE d.id = l.device_id AND d.user_id = usr AND l.e2ee_circle_id = circ
        RETURNING l.ts)
    SELECT array_agg(ts) INTO tss FROM del;
    IF tss IS NOT NULL THEN
        UPDATE member_positions mp SET lat = n.lat, lon = n.lon, ts = n.ts, device_id = n.device_id,
               accuracy_meters = n.acc, speed_mps = n.spd, battery_pct = n.bat, heading_deg = NULL, motion_state = NULL
          FROM (SELECT ST_Y(l.geom) AS lat, ST_X(l.geom) AS lon, l.ts, l.device_id, l.accuracy_meters AS acc,
                       l.speed_mps AS spd, l.battery_pct AS bat
                  FROM locations l JOIN devices d ON d.id = l.device_id
                 WHERE d.user_id = usr AND (l.e2ee_circle_id IS NULL OR e2ee_member_server_ok(l.e2ee_circle_id, usr))
                 ORDER BY l.ts DESC LIMIT 1) n
         WHERE mp.user_id = usr AND mp.ts = ANY (tss);
        -- no other location remains: a last position that was one of the purged points goes
        DELETE FROM member_positions WHERE user_id = usr AND ts = ANY (tss);
    END IF;
    -- Every server-line item of ANY purpose the member authored is readable by the
    -- server under SK (check-ins and events carry positions, places and chats carry
    -- place and message data): all of them go. Phones keep what they already pulled;
    -- members who had not pulled them yet lose them.
    DELETE FROM e2ee_items i USING device_keys k
     WHERE i.circle_id = circ AND i.key_line = 'server'
       AND k.device_id = i.device_id AND k.user_id = usr;
END $$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------ triggers

-- CK is never wrapped to a server-kind device (outside a legacy circle); SK only
-- while the policy is on and a member is in lane server. Applies to INSERT and UPDATE.
CREATE OR REPLACE FUNCTION e2ee_wrap_guard() RETURNS trigger AS $$
DECLARE
    k   TEXT;
    c   circles%ROWTYPE;
BEGIN
    SELECT kind INTO k FROM device_keys WHERE device_id = NEW.recipient_device_id;
    IF k = 'server' THEN
        SELECT * INTO c FROM circles WHERE id = NEW.circle_id;
        IF NEW.key_line = 'phone' THEN
            IF NOT COALESCE(c.server_legacy_ck, FALSE) THEN
                RAISE EXCEPTION 'e2ee_ck_to_server: the phone key is never wrapped to a server device'
                    USING ERRCODE = 'check_violation';
            END IF;
        ELSIF NOT (COALESCE(c.e2ee_mode = 'private' AND c.server_assist, FALSE)
                   AND EXISTS (SELECT 1 FROM e2ee_processing_pref p WHERE p.circle_id = NEW.circle_id AND p.lane = 'server')) THEN
            RAISE EXCEPTION 'e2ee_sk_to_server: the server key needs the admin policy on and a member in lane server'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_wrap_guard ON circle_key_wraps;
CREATE TRIGGER trg_e2ee_wrap_guard BEFORE INSERT OR UPDATE ON circle_key_wraps
    FOR EACH ROW EXECUTE FUNCTION e2ee_wrap_guard();

-- A key's kind never changes (a phone key must not become a server key after
-- it received a CK wrap).
CREATE OR REPLACE FUNCTION e2ee_device_kind_immutable() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'e2ee: a device key''s kind cannot change' USING ERRCODE = 'check_violation';
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_device_kind_immutable ON device_keys;
CREATE TRIGGER trg_e2ee_device_kind_immutable BEFORE UPDATE OF kind ON device_keys
    FOR EACH ROW WHEN (OLD.kind IS DISTINCT FROM NEW.kind) EXECUTE FUNCTION e2ee_device_kind_immutable();

-- Item routing backstop: a server-line item needs policy on and an author in lane
-- server; in a required_server circle every item needs the server lane; epochs
-- closed by the legacy upgrade accept nothing more.
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
DROP TRIGGER IF EXISTS trg_e2ee_item_guard ON e2ee_items;
CREATE TRIGGER trg_e2ee_item_guard BEFORE INSERT ON e2ee_items
    FOR EACH ROW EXECUTE FUNCTION e2ee_item_guard();

-- When the last lane-server preference goes (member left / switched), the
-- server key's SK wraps are revoked.
CREATE OR REPLACE FUNCTION e2ee_pref_server_lane_changed() RETURNS trigger AS $$
BEGIN
    -- Leaving the server lane (or the pref disappearing) removes the server's copies
    -- of this member in the same transaction.
    IF OLD.lane = 'server' AND (TG_OP = 'DELETE' OR NEW.lane <> 'server') THEN
        PERFORM e2ee_purge_user_server_copies(OLD.circle_id, OLD.user_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM e2ee_processing_pref p WHERE p.circle_id = OLD.circle_id AND p.lane = 'server') THEN
        DELETE FROM circle_key_wraps w USING device_keys d
         WHERE w.circle_id = OLD.circle_id AND w.key_line = 'server' AND d.device_id = w.recipient_device_id AND d.kind = 'server';
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_pref_server_lane_changed ON e2ee_processing_pref;
CREATE TRIGGER trg_e2ee_pref_server_lane_changed AFTER UPDATE OR DELETE ON e2ee_processing_pref
    FOR EACH ROW EXECUTE FUNCTION e2ee_pref_server_lane_changed();

-- Policy turned off: the server loses its SK wraps and every lane-server pref.
CREATE OR REPLACE FUNCTION e2ee_policy_turned_off() RETURNS trigger AS $$
BEGIN
    DELETE FROM circle_key_wraps w USING device_keys d
     WHERE w.circle_id = NEW.id AND w.key_line = 'server' AND d.device_id = w.recipient_device_id AND d.kind = 'server';
    DELETE FROM e2ee_processing_pref WHERE circle_id = NEW.id AND lane = 'server';
    RETURN NULL;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_policy_turned_off ON circles;
CREATE TRIGGER trg_e2ee_policy_turned_off AFTER UPDATE OF server_assist ON circles
    FOR EACH ROW WHEN (OLD.server_assist AND NOT NEW.server_assist) EXECUTE FUNCTION e2ee_policy_turned_off();

-- Leaving private mode (or entering it again) resets the policy and every pref;
-- the SK generation counter is kept so a generation never repeats.
CREATE OR REPLACE FUNCTION e2ee_processing_mode_changed() RETURNS trigger AS $$
BEGIN
    DELETE FROM e2ee_processing_pref WHERE circle_id = NEW.id;
    NEW.server_assist := FALSE;
    NEW.server_assist_default := 'phone';
    NEW.member_opt_out := 'allowed';
    NEW.e2ee_server_commitment := NULL;
    NEW.e2ee_server_rekey_required := FALSE;
    NEW.server_legacy_ck := FALSE;
    NEW.server_legacy_epoch_max := 0;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_processing_mode_changed ON circles;
CREATE TRIGGER trg_e2ee_processing_mode_changed BEFORE UPDATE OF e2ee_mode ON circles
    FOR EACH ROW WHEN (OLD.e2ee_mode IS DISTINCT FROM NEW.e2ee_mode) EXECUTE FUNCTION e2ee_processing_mode_changed();

-- A member who leaves loses their pref (a rejoin starts phone-only).
CREATE OR REPLACE FUNCTION e2ee_processing_pref_member_removed() RETURNS trigger AS $$
BEGIN
    DELETE FROM e2ee_processing_pref WHERE circle_id = OLD.circle_id AND user_id = OLD.user_id;
    PERFORM e2ee_purge_user_server_copies(OLD.circle_id, OLD.user_id);
    RETURN OLD;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_processing_pref_member_removed ON circle_members;
CREATE TRIGGER trg_e2ee_processing_pref_member_removed AFTER DELETE ON circle_members
    FOR EACH ROW EXECUTE FUNCTION e2ee_processing_pref_member_removed();

-- A revoked phone key can no longer stand behind a pref: the prefs it signed go
-- (their owners fall back to phone) and the server's copies with them. A legacy
-- consent signed by it is dropped and its owner's copies are removed too.
CREATE OR REPLACE FUNCTION e2ee_processing_key_revoked() RETURNS trigger AS $$
DECLARE
    r RECORD;
BEGIN
    IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
        -- Lock every private circle of this user up front, in id order (this trigger is
        -- named to fire before e2ee_device_revoked, which updates the same rows), so
        -- concurrent revocations cannot deadlock and ingest is serialised (see purge).
        PERFORM 1 FROM circles WHERE e2ee_mode = 'private'
                 AND id IN (SELECT circle_id FROM circle_members WHERE user_id = NEW.user_id) ORDER BY id FOR UPDATE;
        DELETE FROM e2ee_processing_pref WHERE approver_device_id = NEW.device_id;
        FOR r IN SELECT circle_id, user_id FROM e2ee_server_consents WHERE approver_device_id = NEW.device_id LOOP
            DELETE FROM e2ee_server_consents WHERE circle_id = r.circle_id AND user_id = r.user_id;
            PERFORM e2ee_purge_user_server_copies(r.circle_id, r.user_id);
        END LOOP;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_aa_processing_key_revoked ON device_keys;
CREATE TRIGGER trg_e2ee_aa_processing_key_revoked AFTER UPDATE OF revoked_at ON device_keys
    FOR EACH ROW EXECUTE FUNCTION e2ee_processing_key_revoked();

-- Member removal / key revocation request a new generation of BOTH lines.
CREATE OR REPLACE FUNCTION e2ee_member_removed() RETURNS trigger AS $$
BEGIN
    DELETE FROM circle_key_wraps w
     USING device_keys d
     WHERE w.circle_id = OLD.circle_id AND d.device_id = w.recipient_device_id AND d.user_id = OLD.user_id;
    UPDATE circles SET e2ee_rekey_required = TRUE, e2ee_server_rekey_required = (e2ee_server_rekey_required OR server_assist),
           e2ee_updated_at = now()
     WHERE id = OLD.circle_id AND e2ee_mode = 'private';
    RETURN OLD;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION e2ee_device_revoked() RETURNS trigger AS $$
BEGIN
    IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
        DELETE FROM circle_key_wraps WHERE recipient_device_id = NEW.device_id;
        UPDATE circles SET e2ee_rekey_required = TRUE, e2ee_server_rekey_required = (e2ee_server_rekey_required OR server_assist),
               e2ee_updated_at = now()
         WHERE e2ee_mode = 'private'
           AND id IN (SELECT circle_id FROM circle_members WHERE user_id = NEW.user_id);
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

-- Old apps (no 'lanes2') cannot verify the key log once it holds processing_pref /
-- processing_policy entries (action codes 10 and 11): they would go blind to
-- key-change alarms. So (a) such an entry can only be appended while no live member
-- has an active phone key without lanes2, (b) nobody with such a key joins a circle
-- that already has such entries, and (c) such a key cannot be registered by a member
-- of such a circle. The handlers answer 409 update_required_for_lanes first; these
-- triggers are the backstop for every other path.
CREATE INDEX IF NOT EXISTS idx_e2ee_log_circle_lanes ON e2ee_log (circle_id) WHERE action IN (10, 11);
CREATE OR REPLACE FUNCTION e2ee_circle_has_lanes_log(circ UUID) RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM e2ee_log WHERE circle_id = circ AND action IN (10, 11))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION e2ee_log_lanes_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.circle_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM live_circle_members m JOIN device_keys d ON d.user_id = m.user_id
         WHERE m.circle_id = NEW.circle_id AND d.kind = 'device' AND d.revoked_at IS NULL AND NOT ('lanes2' = ANY (d.caps))) THEN
        RAISE EXCEPTION 'e2ee_update_required_for_lanes: a member still runs an app that cannot read processing log entries'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_log_lanes_guard ON e2ee_log;
CREATE TRIGGER trg_e2ee_log_lanes_guard BEFORE INSERT ON e2ee_log
    FOR EACH ROW WHEN (NEW.action IN (10, 11)) EXECUTE FUNCTION e2ee_log_lanes_guard();

CREATE OR REPLACE FUNCTION e2ee_member_lanes_guard() RETURNS trigger AS $$
BEGIN
    IF e2ee_circle_has_lanes_log(NEW.circle_id) AND EXISTS (
        SELECT 1 FROM device_keys d WHERE d.user_id = NEW.user_id AND d.kind = 'device' AND d.revoked_at IS NULL
           AND NOT ('lanes2' = ANY (d.caps))) THEN
        RAISE EXCEPTION 'e2ee_update_required_for_lanes: update the app to join this circle' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_member_lanes_guard ON circle_members;
CREATE TRIGGER trg_e2ee_member_lanes_guard BEFORE INSERT ON circle_members
    FOR EACH ROW EXECUTE FUNCTION e2ee_member_lanes_guard();

CREATE OR REPLACE FUNCTION e2ee_device_lanes_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.kind = 'device' AND NOT ('lanes2' = ANY (NEW.caps)) AND EXISTS (
        SELECT 1 FROM circle_members m WHERE m.user_id = NEW.user_id AND e2ee_circle_has_lanes_log(m.circle_id)) THEN
        RAISE EXCEPTION 'e2ee_update_required_for_lanes: update the app to register a key' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_device_lanes_guard ON device_keys;
CREATE TRIGGER trg_e2ee_device_lanes_guard BEFORE INSERT ON device_keys
    FOR EACH ROW EXECUTE FUNCTION e2ee_device_lanes_guard();

-- Circles that were ALREADY in trusted-server mode (any consent row or a wrap to
-- a server key) stay legacy until their admin runs the upgrade action. New
-- circles can never be legacy: no API sets the flag.
UPDATE circles c SET server_legacy_ck = TRUE
 WHERE c.e2ee_mode = 'private' AND NOT c.server_legacy_ck AND NOT c.server_assist
   AND c.e2ee_server_gen = 0 AND c.server_legacy_epoch_max = 0
   AND (EXISTS (SELECT 1 FROM e2ee_server_consents sc WHERE sc.circle_id = c.id)
        OR EXISTS (SELECT 1 FROM circle_key_wraps w JOIN device_keys d ON d.device_id = w.recipient_device_id
                    WHERE w.circle_id = c.id AND d.kind = 'server'));
