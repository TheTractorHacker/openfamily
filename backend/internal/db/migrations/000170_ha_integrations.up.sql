-- 000170_ha_integrations.up.sql
-- Home Assistant integration (docs/integrations/home-assistant.md).
--
-- ha_integrations: one row per scoped, revocable integration token. Only
-- SHA-256(token) is stored (the token is shown once, at creation). The row
-- carries the token's scopes and circle scope and, optionally, the webhook the
-- server pushes events to. webhook_secret is the HMAC key for those pushes; it
-- must be readable by the server to sign, so it is stored as-is (it is NOT a
-- login credential and cannot read anything).
--
-- ha_events: a short-lived outbox of event facts (no coordinates, no names of
-- anything the token holder could not already see). Each integration's
-- visibility rules are applied again when an event is delivered.
--
-- Idempotent.

CREATE TABLE IF NOT EXISTS ha_integrations (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                  TEXT NOT NULL,
    token_hash            BYTEA NOT NULL UNIQUE,
    token_hint            TEXT NOT NULL DEFAULT '',
    scopes                TEXT[] NOT NULL,
    circle_ids            UUID[] NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at          TIMESTAMPTZ,
    revoked_at            TIMESTAMPTZ,

    webhook_url           TEXT NOT NULL DEFAULT '',
    webhook_secret        TEXT NOT NULL DEFAULT '',
    webhook_allow_private BOOLEAN NOT NULL DEFAULT FALSE,
    webhook_events        TEXT[] NOT NULL DEFAULT '{}',
    webhook_cursor        BIGINT NOT NULL DEFAULT 0,
    webhook_failures      INTEGER NOT NULL DEFAULT 0,
    webhook_next_attempt  TIMESTAMPTZ,
    last_delivery_at      TIMESTAMPTZ,
    last_delivery_ok      BOOLEAN,
    last_delivery_code    INTEGER,
    last_delivery_error   TEXT NOT NULL DEFAULT '',
    last_delivery_event   TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_ha_integrations_user ON ha_integrations (user_id);
CREATE INDEX IF NOT EXISTS idx_ha_integrations_webhook ON ha_integrations (id)
    WHERE revoked_at IS NULL AND webhook_url <> '';

CREATE TABLE IF NOT EXISTS ha_events (
    id          BIGSERIAL PRIMARY KEY,
    kind        TEXT NOT NULL,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source_key  TEXT NOT NULL UNIQUE,
    ref_id      UUID,
    place_id    UUID,
    place_name  TEXT NOT NULL DEFAULT '',
    occurred_at TIMESTAMPTZ NOT NULL,
    data        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ha_events_created ON ha_events (created_at);

-- Scanner cursors, one row per source table.
CREATE TABLE IF NOT EXISTS ha_event_cursors (
    source    TEXT PRIMARY KEY,
    cursor_ts TIMESTAMPTZ NOT NULL
);

-- The trip scanner looks for recently ended drives.
CREATE INDEX IF NOT EXISTS idx_trips_ended_at ON trips (ended_at);
