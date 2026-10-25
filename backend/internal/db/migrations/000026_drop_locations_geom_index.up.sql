-- 000026_drop_locations_geom_index.up.sql
-- PERF-004 / INF-014: the GiST index on locations.geom is written on every
-- insert but no query filters locations.geom spatially (it is only read via
-- ST_X/ST_Y; spatial predicates run against places.geom). Dropping it cuts
-- write cost and disk use on the hottest table.
DROP INDEX IF EXISTS idx_locations_geom;
