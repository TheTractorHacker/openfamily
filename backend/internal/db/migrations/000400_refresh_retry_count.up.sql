-- 000400: how many times a SPENT refresh token has been answered again with the same successor (a phone whose
-- answer was lost retries the token). The count is capped, so a replayed token cannot be used indefinitely.
-- NOT NULL with a constant default is metadata-only on PostgreSQL 11+.
ALTER TABLE refresh_sessions ADD COLUMN IF NOT EXISTS retry_count integer NOT NULL DEFAULT 0;
