-- 000080_push_direct.down.sql
DROP TABLE IF EXISTS push_outbox;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_push_transport_check;
ALTER TABLE devices DROP COLUMN IF EXISTS direct_seen_at;
ALTER TABLE devices DROP COLUMN IF EXISTS push_transport;
