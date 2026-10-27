-- Optional push-sync of location history to a self-hosted Dawarich server.
-- Single settings row (id = 1) plus a per-device cursor so each fix is sent once.
CREATE TABLE dawarich_settings (
    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    base_url TEXT NOT NULL DEFAULT '',
    local_url TEXT NOT NULL DEFAULT '',
    api_key TEXT NOT NULL DEFAULT '',
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    last_sync_at TIMESTAMPTZ,
    last_error TEXT NOT NULL DEFAULT '',
    total_sent BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE dawarich_cursor (
    device_id UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    last_ts TIMESTAMPTZ NOT NULL
);
