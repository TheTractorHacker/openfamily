DROP INDEX IF EXISTS idx_chat_messages_client_id;
ALTER TABLE chat_messages DROP COLUMN IF EXISTS client_id;
ALTER TABLE chat_messages DROP COLUMN IF EXISTS edited_at;
