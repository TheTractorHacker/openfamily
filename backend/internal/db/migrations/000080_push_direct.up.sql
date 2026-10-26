-- 000080_push_direct.up.sql
-- Built-in "direct" push channel: an authenticated stream from the server to the
-- app, no third-party distributor (ntfy/FCM) needed. Events wait in a small
-- per-device outbox until the device connects and acknowledges them.

-- Which push transport a device declared. '' keeps today's behaviour
-- (UnifiedPush endpoint / APNs token); 'direct' opts into the stream.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_transport TEXT NOT NULL DEFAULT '';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS direct_seen_at TIMESTAMPTZ;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'devices_push_transport_check') THEN
        ALTER TABLE devices ADD CONSTRAINT devices_push_transport_check
            CHECK (push_transport IN ('', 'direct'));
    END IF;
END $$;

-- At-least-once outbox. (device_id, dedupe_id) is unique, so enqueueing the same
-- event twice is a no-op, and the app dedupes on dedupe_id. Payloads carry no
-- coordinates (enforced by the builder; the size cap is a second guard).
CREATE TABLE IF NOT EXISTS push_outbox (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id  UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dedupe_id  TEXT NOT NULL,
    kind       TEXT NOT NULL CHECK (kind IN ('alert', 'command', 'notice')),
    alert_id   UUID REFERENCES alerts(id) ON DELETE CASCADE,
    payload    JSONB NOT NULL,
    state      TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'sent', 'acked', 'expired')),
    attempts   INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    sent_at    TIMESTAMPTZ,
    acked_at   TIMESTAMPTZ,
    CONSTRAINT push_outbox_dedupe UNIQUE (device_id, dedupe_id),
    CONSTRAINT push_outbox_payload_size CHECK (octet_length(payload::text) <= 2048)
);
CREATE INDEX IF NOT EXISTS idx_push_outbox_pending
    ON push_outbox (device_id, created_at) WHERE state IN ('queued', 'sent');
CREATE INDEX IF NOT EXISTS idx_push_outbox_expiry ON push_outbox (expires_at);
CREATE INDEX IF NOT EXISTS idx_push_outbox_alert ON push_outbox (alert_id, user_id) WHERE alert_id IS NOT NULL;
