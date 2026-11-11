-- 000425: record of the server's "your phone went quiet, please report" wake-ups (stale_wake.go).
-- last_stale_wake_at is when the server last asked THIS device for a fresh report on its own (nobody tapped
-- anything); stale_wake_count is how many such asks in a row got no answer (it starts again at 1 once the device
-- has reported since the last ask). Together they cap the cost: one ask per device per 15 minutes, and none after
-- a fixed number of unanswered asks. Timestamps and counters only: no coordinate. Idempotent.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_stale_wake_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS stale_wake_count integer NOT NULL DEFAULT 0;
