-- 000117_bubble_alerts_expiry_reminder.down.sql
DELETE FROM alerts WHERE type LIKE 'bubble\_%';
ALTER TABLE alerts DROP CONSTRAINT IF EXISTS alerts_type_check;
ALTER TABLE alerts ADD CONSTRAINT alerts_type_check CHECK (type IN ('check_in', 'help', 'sos'));
ALTER TABLE circles DROP COLUMN IF EXISTS expiry_reminded_at;
