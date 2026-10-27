-- 000114_temporary_circles.up.sql
-- Temporary circles (road trip, event). expires_at NULL = permanent. ended_at is
-- set when an admin ends the circle early. A circle is "live" while ended_at IS
-- NULL AND (expires_at IS NULL OR expires_at > now()); every read path treats a
-- non-live circle as non-existent, evaluated in SQL so no job is needed for
-- correctness. A purge loop deletes circles a grace period after they stop
-- being live.
ALTER TABLE circles ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE circles ADD COLUMN IF NOT EXISTS ended_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_circles_expires ON circles (expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_circles_ended ON circles (ended_at) WHERE ended_at IS NOT NULL;

-- circle_members restricted to live circles. Authorization reads use this.
CREATE OR REPLACE VIEW live_circle_members AS
SELECT cm.circle_id, cm.user_id, cm.role, cm.sharing_enabled, cm.joined_at
FROM circle_members cm
JOIN circles c ON c.id = cm.circle_id
WHERE c.ended_at IS NULL AND (c.expires_at IS NULL OR c.expires_at > now());
