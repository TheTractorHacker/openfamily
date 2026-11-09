-- Web access from any browser (docs/design/WEB_VIEWER_ANYWHERE.md). One sealed
-- "viewer vault" per account: an opaque blob holding a web viewer key sealed
-- under the owner's vault passphrase. The server cannot open it: no column here
-- holds a key, a passphrase or anything derived from one in usable form.
CREATE TABLE IF NOT EXISTS e2ee_viewer_vaults (
    user_id        UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- The registered web key whose seed the blob seals. Deleting or revoking
    -- that key deletes the vault (trigger below), so a revoke from a phone ends
    -- web access in every browser.
    device_id      UUID NOT NULL REFERENCES device_keys(device_id) ON DELETE CASCADE,
    blob           JSONB NOT NULL CHECK (octet_length(blob::text) <= 8192),
    -- Sealed key-log head (seq is public, the rest is ciphertext); only grows.
    pin            JSONB CHECK (pin IS NULL OR octet_length(pin::text) <= 1024),
    pin_seq        BIGINT NOT NULL DEFAULT 0,
    -- Which server pepper file the blob was sealed with (a non-secret tag), so a
    -- lost or replaced file is reported instead of a "wrong passphrase".
    pepper_id      TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_opened_at TIMESTAMPTZ
);

-- Browsers that have unlocked the vault (SHA-256 of a random id the browser
-- keeps), so the owner's phones are told about each NEW browser.
CREATE TABLE IF NOT EXISTS e2ee_viewer_vault_browsers (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    browser     TEXT NOT NULL CHECK (browser ~ '^[0-9a-f]{64}$'),
    first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, browser)
);

CREATE OR REPLACE FUNCTION e2ee_viewer_vault_on_revoke() RETURNS trigger AS $$
BEGIN
    IF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
        DELETE FROM e2ee_viewer_vaults WHERE device_id = NEW.device_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_e2ee_viewer_vault_on_revoke ON device_keys;
CREATE TRIGGER trg_e2ee_viewer_vault_on_revoke AFTER UPDATE OF revoked_at ON device_keys
    FOR EACH ROW EXECUTE FUNCTION e2ee_viewer_vault_on_revoke();

-- The admin switch lives in app_theme_settings (created at startup by
-- EnsureThemeSchema, which adds e2ee_viewer_vault_enabled, default on).
