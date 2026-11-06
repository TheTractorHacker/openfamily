-- 000175_reliability.up.sql
-- Phone diagnostics, "phone went silent" alerts and missed-arrival alerts.
-- Everything here is coordinate-free metadata (timestamps, counts, states) so
-- it is safe for Private (end-to-end encrypted) circles too. Idempotent.

-- What the phone itself reported about its own health (PUT /devices/{id}/diagnostics).
ALTER TABLE devices ADD COLUMN IF NOT EXISTS os_version        TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS battery_opt       TEXT;        -- unrestricted | optimized | restricted | unknown
ALTER TABLE devices ADD COLUMN IF NOT EXISTS outbox_pending    INTEGER;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS loc_permission    TEXT;        -- always | while_in_use | denied | unknown
ALTER TABLE devices ADD COLUMN IF NOT EXISTS notif_permission  TEXT;        -- granted | denied | unknown
ALTER TABLE devices ADD COLUMN IF NOT EXISTS bg_service        BOOLEAN;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS diag_reported_at  TIMESTAMPTZ;
-- Server-observed push outcomes per device.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_push_ok_at   TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_push_fail_at TIMESTAMPTZ;

-- Per-user liveness the server observed (any location upload, batch, heartbeat
-- or encrypted-item upload). Survives the short TTL of encrypted live items.
CREATE TABLE IF NOT EXISTS member_report_state (
    user_id        UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    last_report_at TIMESTAMPTZ NOT NULL,
    last_ws_at     TIMESTAMPTZ
);

-- One row per user per UTC hour in which the server heard from the phone; the
-- basis for "the hours this phone normally reports". Pruned after 28 days.
CREATE TABLE IF NOT EXISTS member_report_hours (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hour    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, hour)
);

-- Silent-phone alerts. Off (0) by default; a circle admin picks the threshold.
ALTER TABLE circles ADD COLUMN IF NOT EXISTS silence_alert_hours INTEGER NOT NULL DEFAULT 0
    CHECK (silence_alert_hours = 0 OR silence_alert_hours BETWEEN 2 AND 72);

CREATE TABLE IF NOT EXISTS silence_member_prefs (
    circle_id     UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    disabled      BOOLEAN NOT NULL DEFAULT FALSE,
    snoozed_until TIMESTAMPTZ,
    PRIMARY KEY (circle_id, user_id)
);

-- Idempotency: one alert per silence episode. A new episode starts when the
-- member reports again (last_report_at moves past the stored value).
CREATE TABLE IF NOT EXISTS silence_alert_state (
    circle_id      UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_report_at TIMESTAMPTZ NOT NULL,
    alerted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (circle_id, user_id)
);

-- notification_prefs.phone_silent is added by EnsureNotificationSchema (that table is server-managed).
