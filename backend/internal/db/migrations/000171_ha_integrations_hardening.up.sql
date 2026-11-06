-- 000171_ha_integrations_hardening.up.sql
-- * ha_integrations.owner_token_version: a token only works while its owner's
--   users.token_version is unchanged (password change/reset, logout everywhere,
--   TOTP change all bump it), so those events end the owner's integrations.
-- * ha_events.place_circle_id: the circle a place belonged to when the event was
--   recorded, so the circle check still works after the place is deleted.
ALTER TABLE ha_integrations ADD COLUMN IF NOT EXISTS owner_token_version INTEGER NOT NULL DEFAULT 0;
UPDATE ha_integrations h SET owner_token_version = u.token_version FROM users u WHERE u.id = h.user_id AND h.owner_token_version = 0;
ALTER TABLE ha_events ADD COLUMN IF NOT EXISTS place_circle_id UUID;
