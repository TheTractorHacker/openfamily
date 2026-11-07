-- App/API compatibility (docs/api-compat.md). Idempotent.
--
-- app_client_versions: which app versions each user has been seen using, fed by
-- the X-App-Version request header and written at most once per
-- (user, version, platform) per 10 minutes by the server.
CREATE TABLE IF NOT EXISTS app_client_versions (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    app_version TEXT NOT NULL,
    platform    TEXT NOT NULL DEFAULT '',
    first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, app_version, platform)
);
CREATE INDEX IF NOT EXISTS app_client_versions_last_seen_idx ON app_client_versions (last_seen DESC);

-- app_compat_settings: one row of operator settings. min_supported_override
-- ("" = use MIN_SUPPORTED_APP_VERSION or the rolling window) and
-- enforce_writes (answer 426 to location writes from versions below the
-- minimum; off by default).
CREATE TABLE IF NOT EXISTS app_compat_settings (
    id                     SMALLINT PRIMARY KEY CHECK (id = 1),
    min_supported_override TEXT NOT NULL DEFAULT '',
    enforce_writes         BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO app_compat_settings (id) VALUES (1) ON CONFLICT DO NOTHING;
