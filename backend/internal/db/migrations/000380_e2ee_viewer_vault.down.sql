DROP TRIGGER IF EXISTS trg_e2ee_viewer_vault_on_revoke ON device_keys;
DROP FUNCTION IF EXISTS e2ee_viewer_vault_on_revoke();
DROP TABLE IF EXISTS e2ee_viewer_vault_browsers;
DROP TABLE IF EXISTS e2ee_viewer_vaults;
