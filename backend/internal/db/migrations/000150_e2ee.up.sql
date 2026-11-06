-- 000150_e2ee.up.sql
-- End-to-end encryption foundation, phase 1 (docs/design/E2EE.md).
--
-- The server stores PUBLIC keys and CIPHERTEXT only. Nothing in these tables can
-- decrypt anything: private keys and circle keys never reach the server.
-- Idempotent: safe to run again.

-- One row per device identity (Ed25519 signing key + X25519 agreement key).
CREATE TABLE IF NOT EXISTS device_keys (
    -- Chosen by the client (random v4) because it is inside signed messages.
    device_id    UUID PRIMARY KEY,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ed25519_pub  BYTEA NOT NULL CHECK (octet_length(ed25519_pub) = 32),
    x25519_pub   BYTEA NOT NULL CHECK (octet_length(x25519_pub) = 32),
    -- hex SHA-256("OFE2EE1-FP\0" || ed25519_pub || x25519_pub)
    fingerprint  TEXT NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    -- Ed25519 signature over "OFE2EE1-BIND\0" || user_id || ed25519_pub || x25519_pub
    signature    BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    -- 'device' = a phone's identity; 'recovery' = the identity derived from the
    -- user's recovery phrase (only its PUBLIC half is ever here).
    kind         TEXT NOT NULL DEFAULT 'device' CHECK (kind IN ('device', 'recovery')),
    -- Who vouched for this key: the registering key itself (a root) or an
    -- existing key of the same user (cross-signature). registration_signature is
    -- that actor's signature over the transparency-log action message.
    registered_by_device_id UUID NOT NULL,
    registered_by_pub       BYTEA NOT NULL CHECK (octet_length(registered_by_pub) = 32),
    registration_action     SMALLINT NOT NULL,
    registration_signature  BYTEA NOT NULL CHECK (octet_length(registration_signature) = 64),
    -- The user's very first key ever needs no approval (trust-on-first-use plus
    -- the inviter fingerprint in the invite). Any later root key does.
    initial      BOOLEAN NOT NULL DEFAULT FALSE,
    label        TEXT NOT NULL DEFAULT '' CHECK (char_length(label) <= 60),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at   TIMESTAMPTZ,
    revoked_reason TEXT CHECK (revoked_reason IN ('revoked', 'rotated'))
);
CREATE INDEX IF NOT EXISTS idx_device_keys_user ON device_keys (user_id);
-- A public key identifies exactly one active device.
CREATE UNIQUE INDEX IF NOT EXISTS uq_device_keys_active_ed ON device_keys (ed25519_pub) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_device_keys_active_recovery ON device_keys (user_id) WHERE kind = 'recovery' AND revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_device_keys_active_fp ON device_keys (fingerprint) WHERE revoked_at IS NULL;

-- Circle E2EE state. e2ee_epoch only ever grows (it is kept when a circle is
-- switched back to 'off' so an old wrap can never be replayed as current).
ALTER TABLE circles ADD COLUMN IF NOT EXISTS e2ee_mode TEXT NOT NULL DEFAULT 'off';
ALTER TABLE circles ADD COLUMN IF NOT EXISTS e2ee_epoch INTEGER NOT NULL DEFAULT 0;
-- Set by triggers when a member leaves/is removed or a device key is revoked:
-- an admin's phone must publish the next epoch (new key, re-wrapped to the
-- remaining devices). The server cannot do this itself; it never holds a key.
ALTER TABLE circles ADD COLUMN IF NOT EXISTS e2ee_rekey_required BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE circles ADD COLUMN IF NOT EXISTS e2ee_updated_at TIMESTAMPTZ;
DO $$ BEGIN
    ALTER TABLE circles ADD CONSTRAINT circles_e2ee_mode_chk CHECK (e2ee_mode IN ('off', 'private'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TABLE circles ADD CONSTRAINT circles_e2ee_epoch_chk CHECK (e2ee_epoch >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Admin approvals of replacement devices, per circle. A device that is neither the
-- user's first key nor cross-signed by one of the user's existing keys receives
-- no wraps in a circle until a circle admin (another user) approves it there.
CREATE TABLE IF NOT EXISTS device_approvals (
    device_id          UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    circle_id          UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    approver_user_id   UUID NOT NULL,
    approver_device_id UUID NOT NULL,
    approver_pub       BYTEA NOT NULL CHECK (octet_length(approver_pub) = 32),
    signature          BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, circle_id)
);

-- Key transparency log: one append-only, hash-chained sequence. Every entry is
-- signed by the acting device. entry_hash = SHA-256("OFE2EE1-LOG\0" || prev ||
-- seq || action message || signature). Clients pin the head and alarm on any
-- fork, rollback or rewrite. Rows are never updated or deleted (trigger below).
CREATE TABLE IF NOT EXISTS e2ee_log (
    seq             BIGINT PRIMARY KEY,
    action          SMALLINT NOT NULL,
    user_id         UUID NOT NULL,
    actor_device_id UUID NOT NULL,
    actor_pub       BYTEA NOT NULL CHECK (octet_length(actor_pub) = 32),
    circle_id       UUID,
    subject_id      UUID,
    epoch           INTEGER NOT NULL DEFAULT 0,
    ref             BYTEA NOT NULL CHECK (octet_length(ref) = 32),
    signature       BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    prev_hash       BYTEA NOT NULL CHECK (octet_length(prev_hash) = 32),
    entry_hash      BYTEA NOT NULL CHECK (octet_length(entry_hash) = 32),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION e2ee_log_immutable() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'e2ee_log is append-only';
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_log_immutable ON e2ee_log;
CREATE TRIGGER trg_e2ee_log_immutable BEFORE UPDATE OR DELETE ON e2ee_log
    FOR EACH ROW EXECUTE FUNCTION e2ee_log_immutable();

-- Circle key wraps: the circle key for one epoch, sealed to one device.
CREATE TABLE IF NOT EXISTS circle_key_wraps (
    circle_id           UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    epoch               INTEGER NOT NULL CHECK (epoch >= 1),
    recipient_device_id UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    -- No FK: the wrap must stay readable if the wrapper's account is deleted.
    wrapper_device_id   UUID NOT NULL,
    wrapper_ed25519_pub BYTEA NOT NULL CHECK (octet_length(wrapper_ed25519_pub) = 32),
    -- version(1) || ephemeral X25519 pub(32) || nonce(24) || ct(32) || tag(16)
    wrapped_key         BYTEA NOT NULL CHECK (octet_length(wrapped_key) = 105),
    signature           BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (circle_id, epoch, recipient_device_id)
);
CREATE INDEX IF NOT EXISTS idx_circle_key_wraps_recipient ON circle_key_wraps (recipient_device_id);

-- A removed member must lose their wraps and force a re-key.
CREATE OR REPLACE FUNCTION e2ee_member_removed() RETURNS trigger AS $$
BEGIN
    DELETE FROM circle_key_wraps w
     USING device_keys d
     WHERE w.circle_id = OLD.circle_id AND d.device_id = w.recipient_device_id AND d.user_id = OLD.user_id;
    UPDATE circles SET e2ee_rekey_required = TRUE, e2ee_updated_at = now()
     WHERE id = OLD.circle_id AND e2ee_mode = 'private';
    RETURN OLD;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_e2ee_member_removed ON circle_members;
CREATE TRIGGER trg_e2ee_member_removed AFTER DELETE ON circle_members
    FOR EACH ROW EXECUTE FUNCTION e2ee_member_removed();

-- A revoked device must stop receiving wraps and force a re-key of every
-- private circle its owner belongs to.
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
DROP TRIGGER IF EXISTS trg_e2ee_device_revoked ON device_keys;
CREATE TRIGGER trg_e2ee_device_revoked AFTER UPDATE OF revoked_at ON device_keys
    FOR EACH ROW EXECUTE FUNCTION e2ee_device_revoked();
