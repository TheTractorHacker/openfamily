-- 000115_places_circle.down.sql
DROP INDEX IF EXISTS idx_places_circle;
ALTER TABLE places DROP COLUMN IF EXISTS circle_id;
