-- Deployment profile (docs/design/PRIVACY_PROCESSING.md section 21). Idempotent.
--
-- server_profile: one row. deployment_profile is NULL until the admin chooses
-- ('home' = hardware the family owns, 'cloud' = rented/hosted server). NULL is
-- treated as the careful profile ('cloud') by the server and the apps, so an
-- unconfigured box never behaves like a home box.
CREATE TABLE IF NOT EXISTS server_profile (
    id                   SMALLINT PRIMARY KEY CHECK (id = 1),
    deployment_profile   TEXT CHECK (deployment_profile IN ('home', 'cloud')),
    profile_set_at       TIMESTAMPTZ,
    profile_set_by       UUID REFERENCES users(id) ON DELETE SET NULL,
    setup_dismissed_at   TIMESTAMPTZ,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO server_profile (id) VALUES (1) ON CONFLICT DO NOTHING;

-- at_rest_keys: the data key (DEK) that seals a few secret columns, stored ONLY
-- wrapped by the operator's key (OPENFAMILY_DATA_KEY), which is never stored.
CREATE TABLE IF NOT EXISTS at_rest_keys (
    id            SMALLINT PRIMARY KEY CHECK (id = 1),
    wrapped_dek   BYTEA NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    rewrapped_at  TIMESTAMPTZ
);
