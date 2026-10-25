-- 000060_circles.down.sql
-- Drops the circle tables. Legacy data (families, users.family_id) is untouched,
-- so rolling back loses only circles that are not families and per-circle
-- sharing choices.
DROP TRIGGER IF EXISTS trg_circle_members_user ON users;
DROP TRIGGER IF EXISTS trg_circles_family_ins ON families;
DROP TRIGGER IF EXISTS trg_circles_family_upd ON families;
DROP TRIGGER IF EXISTS trg_circles_family_del ON families;
DROP FUNCTION IF EXISTS circle_members_sync_from_user();
DROP FUNCTION IF EXISTS circles_sync_from_family();
DROP TABLE IF EXISTS circle_members;
DROP TABLE IF EXISTS circles;
