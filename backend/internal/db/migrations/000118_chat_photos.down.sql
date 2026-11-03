-- 000118_chat_photos.down.sql
DELETE FROM chat_messages WHERE image_data IS NOT NULL;
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_body_or_image_check;
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_body_check;
ALTER TABLE chat_messages ADD CONSTRAINT chat_messages_body_check CHECK (char_length(body) BETWEEN 1 AND 2000);
ALTER TABLE chat_messages DROP COLUMN IF EXISTS image_content_type;
ALTER TABLE chat_messages DROP COLUMN IF EXISTS image_data;
