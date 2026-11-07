-- 000250_chat_e2ee.up.sql
-- Encrypted family chat (docs/design/E2EE_CHAT.md).
--
-- 1. Chat items on the relay are sealed under the PHONE key line only. A chat
--    item with key_line='server' is refused by the database (NOT VALID: rows
--    that might already exist are not rewritten, every new row is checked).
-- 2. Chat is never processed by the server, so a required_server circle must not
--    block a member's chat just because they have not picked the server lane.
-- 3. Plaintext chat can no longer be inserted into a private circle.
-- 4. chat_reads gets a second cursor in the space of relay item ids so the
--    unread badge of an encrypted chat works from metadata only.
-- 5. e2ee_blobs: opaque encrypted attachments (photos), keyed by a per-file
--    key that only travels inside the sealed chat message.

DO $$ BEGIN
    ALTER TABLE e2ee_items ADD CONSTRAINT e2ee_items_chat_phone_only
        CHECK (purpose <> 'chat' OR key_line = 'phone') NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

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

CREATE OR REPLACE FUNCTION chat_plaintext_guard() RETURNS trigger AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM circles WHERE id = NEW.circle_id AND e2ee_mode = 'private') THEN
        RAISE EXCEPTION 'e2ee_chat_encrypted: this circle chats end-to-end encrypted; plaintext chat is refused'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_chat_plaintext_guard ON chat_messages;
CREATE TRIGGER trg_chat_plaintext_guard BEFORE INSERT ON chat_messages
    FOR EACH ROW EXECUTE FUNCTION chat_plaintext_guard();

ALTER TABLE chat_reads ADD COLUMN IF NOT EXISTS e2ee_item_id BIGINT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS e2ee_blobs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    circle_id   UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    uploader_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    size_bytes  INT NOT NULL CHECK (size_bytes BETWEEN 1 AND 6291456),
    data        BYTEA NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT date_trunc('minute', now()),
    expires_at  TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_e2ee_blobs_circle ON e2ee_blobs (circle_id);
CREATE INDEX IF NOT EXISTS idx_e2ee_blobs_expires ON e2ee_blobs (expires_at);
