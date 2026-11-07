-- Wire efficiency: places gain an updated_at so a phone can ask for only the
-- places that changed since its last sync (GET /family/places?since=).
ALTER TABLE places ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION places_touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS places_touch ON places;
CREATE TRIGGER places_touch BEFORE UPDATE ON places
    FOR EACH ROW EXECUTE FUNCTION places_touch_updated_at();
