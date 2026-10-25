ALTER TABLE refresh_sessions DROP COLUMN IF EXISTS user_agent;
DROP TABLE IF EXISTS password_reset_codes;
DROP TABLE IF EXISTS totp_recovery_codes;
ALTER TABLE users DROP COLUMN IF EXISTS totp_last_step;
