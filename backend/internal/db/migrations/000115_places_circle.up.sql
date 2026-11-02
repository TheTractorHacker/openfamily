-- 000115_places_circle.up.sql
-- Per-circle places. circle_id NULL = family-wide (every existing place), so no
-- data changes. A place with circle_id set is visible to, and fires
-- arrival/departure alerts for, live members of that circle only. Deleting a
-- circle turns its places family-wide would leak them, so they are deleted with
-- it instead (ON DELETE CASCADE).
ALTER TABLE places ADD COLUMN IF NOT EXISTS circle_id UUID REFERENCES circles(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS idx_places_circle ON places (circle_id) WHERE circle_id IS NOT NULL;
