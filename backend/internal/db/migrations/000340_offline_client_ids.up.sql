-- 000340_offline_client_ids.up.sql
-- Offline-first replay (docs/design/OFFLINE_RESILIENCE.md): a phone that could
-- not reach the server queues an SOS / help / check-in and sends it again later,
-- possibly after the first request actually arrived but its answer was lost.
-- The optional client_id (chosen by the phone, unique per sender) makes that
-- replay idempotent, the same way chat_messages.client_id already does.
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS client_id TEXT;
ALTER TABLE checkins ADD COLUMN IF NOT EXISTS client_id TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_alerts_user_client_id ON alerts (user_id, client_id) WHERE client_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_checkins_user_client_id ON checkins (user_id, client_id) WHERE client_id IS NOT NULL;
