-- 000025_locations_unique_device_ts.up.sql
-- PERF-005: enforce one row per (device_id, ts). A unique index on a hypertable
-- must include the partition column (ts), which it does.
--
-- Step 1: remove existing duplicates so the index build cannot fail. Each chunk
-- is deduplicated on its own table, because ctid is only unique within a
-- single table (a hypertable-level ctid comparison could match rows in other
-- chunks). Rows with the same (device_id, ts) always share a chunk. The row
-- with the lowest ctid is kept.
DO $$
DECLARE
    c record;
BEGIN
    FOR c IN
        SELECT format('%I.%I', chunk_schema, chunk_name) AS rel
        FROM timescaledb_information.chunks
        WHERE hypertable_name = 'locations'
          AND NOT is_compressed
    LOOP
        EXECUTE format($q$
            DELETE FROM %s
            WHERE ctid IN (
                SELECT ctid FROM (
                    SELECT ctid,
                           row_number() OVER (PARTITION BY device_id, ts ORDER BY ctid) AS rn
                    FROM %s
                ) d
                WHERE d.rn > 1
            )$q$, c.rel, c.rel);
    END LOOP;
END $$;

-- Step 2: the unique index (idempotent).
CREATE UNIQUE INDEX IF NOT EXISTS idx_locations_device_ts_unique
    ON locations (device_id, ts);
