-- 000118_chat_photos.up.sql
-- Photo messages. The (re-encoded, <=5 MiB) JPEG/PNG bytes live on the message
-- row like avatars do and are only served through an authenticated,
-- circle-member-only endpoint. A photo message may have an empty body.
-- Read receipts reuse chat_reads (last_seq per member); no new table.
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS image_data BYTEA;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS image_content_type TEXT;
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_body_check;
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_body_or_image_check;
ALTER TABLE chat_messages ADD CONSTRAINT chat_messages_body_or_image_check CHECK (
    char_length(body) <= 2000
    AND (char_length(body) >= 1 OR image_data IS NOT NULL)
    AND (image_data IS NULL OR image_content_type IN ('image/jpeg', 'image/png'))
);
