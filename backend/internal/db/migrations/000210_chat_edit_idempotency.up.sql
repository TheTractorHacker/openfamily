-- 000210_chat_edit_idempotency.up.sql
-- Chat v2: edited_at marks an edited message; client_id is an optional
-- sender-chosen id that makes a retried send idempotent (a flaky network no
-- longer produces duplicate messages).
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS client_id TEXT
    CHECK (client_id IS NULL OR char_length(client_id) BETWEEN 1 AND 64);
CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_messages_client_id
    ON chat_messages (circle_id, sender_id, client_id) WHERE client_id IS NOT NULL;
