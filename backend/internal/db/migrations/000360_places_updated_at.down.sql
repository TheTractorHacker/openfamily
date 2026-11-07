DROP TRIGGER IF EXISTS places_touch ON places;
DROP FUNCTION IF EXISTS places_touch_updated_at();
ALTER TABLE places DROP COLUMN IF EXISTS updated_at;
