-- 000027_locations_compression.down.sql
-- Removes the policy only. Compression stays enabled on the table, and chunks
-- that are already compressed stay compressed (decompress them manually with
-- decompress_chunk if needed).
DO $$
BEGIN
    IF to_regproc('remove_compression_policy') IS NOT NULL THEN
        PERFORM remove_compression_policy('locations', if_exists => true);
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'could not remove compression policy: %', SQLERRM;
END $$;
