-- 000119_weekly_summaries.up.sql
-- One row per family per week: the stats the Sunday-evening driving summary was
-- built from. The primary key makes the weekly job idempotent: whoever inserts
-- the row first sends the push, a second run (restart, second replica) is a no-op.
-- week_start is the Monday (UTC) of the summarised week.
CREATE TABLE IF NOT EXISTS weekly_summaries (
    family_id    UUID        NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    week_start   DATE        NOT NULL,
    period_start TIMESTAMPTZ NOT NULL,
    period_end   TIMESTAMPTZ NOT NULL,
    data         JSONB       NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    notified_at  TIMESTAMPTZ,
    PRIMARY KEY (family_id, week_start)
);
