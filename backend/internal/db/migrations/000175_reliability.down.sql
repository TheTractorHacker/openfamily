DROP TABLE IF EXISTS silence_alert_state;
DROP TABLE IF EXISTS silence_member_prefs;
ALTER TABLE circles DROP COLUMN IF EXISTS silence_alert_hours;
DROP TABLE IF EXISTS member_report_hours;
DROP TABLE IF EXISTS member_report_state;
ALTER TABLE devices DROP COLUMN IF EXISTS last_push_fail_at, DROP COLUMN IF EXISTS last_push_ok_at,
    DROP COLUMN IF EXISTS diag_reported_at, DROP COLUMN IF EXISTS bg_service, DROP COLUMN IF EXISTS notif_permission,
    DROP COLUMN IF EXISTS loc_permission, DROP COLUMN IF EXISTS outbox_pending, DROP COLUMN IF EXISTS battery_opt,
    DROP COLUMN IF EXISTS os_version;
-- notification_prefs is created lazily by the server (EnsureNotificationSchema); leave its columns.
