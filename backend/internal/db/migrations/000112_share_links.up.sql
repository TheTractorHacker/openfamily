-- Anyone-with-the-link live location sharing (no app needed). Only a SHA-256 of
-- the random token is stored; the token itself is shown once, at creation.
-- Expiry and revocation are enforced on every read of the public viewer.
CREATE TABLE IF NOT EXISTS share_links (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash BYTEA NOT NULL UNIQUE,
    label      TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT share_links_hash_len CHECK (octet_length(token_hash) = 32)
);
CREATE INDEX IF NOT EXISTS idx_share_links_user ON share_links (user_id, expires_at DESC);
CREATE INDEX IF NOT EXISTS idx_share_links_expires ON share_links (expires_at);
