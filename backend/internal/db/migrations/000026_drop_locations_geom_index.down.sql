-- 000026_drop_locations_geom_index.down.sql
-- Rebuilding on a large hypertable is slow; only needed if a spatial query on
-- locations.geom is added.
CREATE INDEX IF NOT EXISTS idx_locations_geom ON locations USING GIST (geom);
