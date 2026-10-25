# Migrations

Applied automatically at startup by `db.Migrate` (golang-migrate, embedded
`*.sql` files only; this README is not embedded). Never edit an applied
migration; add a new numbered pair with idempotent guards (`IF NOT EXISTS`,
`if_not_exists => true`, `to_regproc(...)` checks).

## Known risks

- **000012_member_positions (INF-013):** the backfill runs
  `SELECT DISTINCT ON (d.user_id) ... FROM locations ... ORDER BY d.user_id, l.ts DESC`,
  a full scan and sort of the `locations` hypertable. It only matters for a
  database that is still below version 12 and already holds many location rows;
  on such an upgrade, startup can take long enough to trip container
  healthchecks. Fresh installs and databases past 12 are unaffected. If you
  must upgrade a large old database, run migrations with a generous start
  period, or pre-populate `member_positions` from the latest row per device
  using a `LATERAL ... ORDER BY ts DESC LIMIT 1` on `idx_locations_device_ts`.
- **A failed migration leaves `schema_migrations.dirty = true`** and the API will
  refuse to start until an operator fixes the state and runs `migrate force`.
  Take a database backup before upgrading.
- **000025** deduplicates `locations` per chunk and builds a unique index
  (`(device_id, ts)`); on a very large table this takes a table lock for the
  duration of the build, so upgrade in a quiet period.
- **000027** enables compression only when TimescaleDB supports it; otherwise it
  logs a NOTICE and continues.

## Retention

The retention policy is not fixed by a migration any more: at startup the server
sets it from `LOCATION_RETENTION_DAYS` (default 90) via `db.ApplyRetentionPolicy`.
000010 still creates the initial 90 day policy.
