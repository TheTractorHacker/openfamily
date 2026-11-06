-- 000135: passkeys (WebAuthn). credential holds the serialized
-- webauthn.Credential (public key, sign counter, flags); the private key never
-- leaves the authenticator. Challenges are short-lived and single use.
CREATE TABLE IF NOT EXISTS passkey_credentials (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id BYTEA NOT NULL UNIQUE,
    credential    JSONB NOT NULL,
    name          TEXT NOT NULL DEFAULT 'Passkey',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS passkey_credentials_user_idx ON passkey_credentials (user_id);

CREATE TABLE IF NOT EXISTS passkey_challenges (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID REFERENCES users(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind IN ('register', 'login')),
    session_data JSONB NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS passkey_challenges_expiry_idx ON passkey_challenges (expires_at);
