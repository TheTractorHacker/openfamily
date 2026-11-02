-- 000117_bubble_alerts_expiry_reminder.up.sql
-- 1) Bubble events (created / subject entered / subject left) are recorded in the
--    alerts history as non-emergency, already-resolved rows of these new types.
-- 2) circles.expiry_reminded_at makes the "ends in about an hour" push for a
--    temporary circle idempotent (set once when the reminder is claimed).
ALTER TABLE alerts DROP CONSTRAINT IF EXISTS alerts_type_check;
ALTER TABLE alerts ADD CONSTRAINT alerts_type_check
    CHECK (type IN ('check_in', 'help', 'sos', 'bubble_created', 'bubble_entered', 'bubble_left'));

ALTER TABLE circles ADD COLUMN IF NOT EXISTS expiry_reminded_at TIMESTAMPTZ;
