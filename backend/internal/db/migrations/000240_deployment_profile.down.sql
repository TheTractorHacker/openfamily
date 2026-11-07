-- REFUSES to drop the data key while it exists: sealed values would become
-- unreadable. Remove or unseal them first (see docs/self-hosting.md).
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM at_rest_keys) THEN
        RAISE EXCEPTION 'refusing to drop at_rest_keys: protected secrets depend on it';
    END IF;
END $$;
DROP TABLE IF EXISTS at_rest_keys;
DROP TABLE IF EXISTS server_profile;
