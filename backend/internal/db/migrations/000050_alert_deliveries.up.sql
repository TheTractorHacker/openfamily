-- 000050_alert_deliveries.up.sql
-- Per-recipient, per-channel delivery state for alerts, plus share-link expiry
-- and revocation. State only reflects what the provider/hub told us: "sent"
-- means a provider accepted the message, "delivered" means it was queued onto a
-- connected WebSocket, "acknowledged" means the recipient confirmed in the app.
CREATE TABLE IF NOT EXISTS alert_deliveries (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id          UUID NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    recipient_key     TEXT NOT NULL,
    recipient_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    contact_id        UUID REFERENCES emergency_contacts(id) ON DELETE SET NULL,
    recipient_label   TEXT NOT NULL DEFAULT '',
    channel           TEXT NOT NULL CHECK (channel IN ('push', 'ws', 'sms')),
    state             TEXT NOT NULL DEFAULT 'queued'
                      CHECK (state IN ('queued', 'sent', 'delivered', 'failed', 'acknowledged')),
    error             TEXT NOT NULL DEFAULT '',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at           TIMESTAMPTZ,
    delivered_at      TIMESTAMPTZ,
    acknowledged_at   TIMESTAMPTZ,
    CONSTRAINT alert_deliveries_error_len CHECK (char_length(error) <= 120),
    CONSTRAINT alert_deliveries_unique UNIQUE (alert_id, recipient_key, channel)
);

CREATE INDEX IF NOT EXISTS idx_alert_deliveries_alert ON alert_deliveries (alert_id);
-- Serves the per-sender and per-family SMS ceilings.
CREATE INDEX IF NOT EXISTS idx_alert_deliveries_sms_recent
    ON alert_deliveries (created_at) WHERE channel = 'sms';

ALTER TABLE alerts ADD COLUMN IF NOT EXISTS share_expires_at TIMESTAMPTZ;
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS share_revoked_at TIMESTAMPTZ;
-- Links created before this migration keep the 24 h lifetime they had.
UPDATE alerts SET share_expires_at = created_at + interval '24 hours' WHERE share_expires_at IS NULL;
