-- 000027_locations_compression.up.sql
-- PERF-004 / INF-014: compress location chunks older than 7 days, segmented by
-- device. Skipped (with a NOTICE) when TimescaleDB compression is unavailable,
-- for example the Apache-licensed community edition or an old version, so the
-- migration never blocks startup.
DO $$
BEGIN
    IF to_regproc('add_compression_policy') IS NULL THEN
        RAISE NOTICE 'timescaledb compression unavailable; skipping 000027';
        RETURN;
    END IF;
    BEGIN
        ALTER TABLE locations SET (
            timescaledb.compress,
            timescaledb.compress_segmentby = 'device_id',
            timescaledb.compress_orderby = 'ts DESC'
        );
        PERFORM add_compression_policy('locations', INTERVAL '7 days', if_not_exists => true);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'could not enable compression on locations, skipping: %', SQLERRM;
    END;
END $$;
