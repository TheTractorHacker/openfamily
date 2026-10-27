-- 000110_circle_chat.up.sql
-- Per-circle family chat. seq is a monotonic cursor for pagination and unread
-- counting (created_at alone can tie). Messages are text only; the length
-- limit is also enforced by the API.
CREATE TABLE IF NOT EXISTS chat_messages (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    seq        BIGINT GENERATED ALWAYS AS IDENTITY,
    circle_id  UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    sender_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_messages_seq ON chat_messages (seq);
CREATE INDEX IF NOT EXISTS idx_chat_messages_circle_seq ON chat_messages (circle_id, seq DESC);

-- How far each member has read in each circle (server-side so the unread badge
-- follows the user across devices).
CREATE TABLE IF NOT EXISTS chat_reads (
    circle_id UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_seq  BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (circle_id, user_id)
);
