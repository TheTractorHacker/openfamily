-- 000060_circles.up.sql
-- Multi-circle data model, stage 1 (additive). See docs/design/CIRCLES.md.
--
-- Every existing family becomes one circle with the SAME id, so nothing that
-- references families(id) (places, geofences, alerts, audit_log, invite_codes)
-- is rewritten. users.family_id stays as the user's "primary circle" and every
-- legacy endpoint keeps reading it. Triggers keep circle_members in step with
-- users.family_id / users.role / families so legacy write paths (create, join,
-- leave, admin move, rename, delete) need no code change.
--
-- Idempotent: safe to run again against a database that already has the tables.

CREATE TABLE IF NOT EXISTS circles (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    icon       TEXT,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS circle_members (
    circle_id       UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')),
    sharing_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (circle_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_circle_members_user ON circle_members (user_id);

-- Backfill: one circle per family (same id), created_by = the family's oldest
-- admin when there is one.
INSERT INTO circles (id, name, created_by, created_at)
SELECT f.id, f.name,
       (SELECT u.id FROM users u
         WHERE u.family_id = f.id AND u.role = 'admin'
         ORDER BY u.created_at, u.id LIMIT 1),
       f.created_at
FROM families f
ON CONFLICT (id) DO NOTHING;

-- Backfill: every user with a family is a member of that circle. The legacy
-- 'child' role has no circle equivalent and maps to 'member'; the legacy
-- users.role stays authoritative for the legacy endpoints.
INSERT INTO circle_members (circle_id, user_id, role)
SELECT u.family_id, u.id, CASE WHEN u.role = 'admin' THEN 'admin' ELSE 'member' END
FROM users u
WHERE u.family_id IS NOT NULL
ON CONFLICT (circle_id, user_id) DO NOTHING;

-- families -> circles
CREATE OR REPLACE FUNCTION circles_sync_from_family() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO circles (id, name, created_at)
        VALUES (NEW.id, NEW.name, NEW.created_at)
        ON CONFLICT (id) DO NOTHING;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE circles SET name = NEW.name WHERE id = NEW.id AND name IS DISTINCT FROM NEW.name;
        RETURN NEW;
    END IF;
    -- DELETE: the family is gone, so is its circle (members cascade).
    DELETE FROM circles WHERE id = OLD.id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_circles_family_ins ON families;
CREATE TRIGGER trg_circles_family_ins AFTER INSERT ON families
    FOR EACH ROW EXECUTE FUNCTION circles_sync_from_family();
DROP TRIGGER IF EXISTS trg_circles_family_upd ON families;
CREATE TRIGGER trg_circles_family_upd AFTER UPDATE OF name ON families
    FOR EACH ROW EXECUTE FUNCTION circles_sync_from_family();
DROP TRIGGER IF EXISTS trg_circles_family_del ON families;
CREATE TRIGGER trg_circles_family_del AFTER DELETE ON families
    FOR EACH ROW EXECUTE FUNCTION circles_sync_from_family();

-- users.family_id / users.role -> circle_members (primary circle membership)
CREATE OR REPLACE FUNCTION circle_members_sync_from_user() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.family_id IS NOT NULL
       AND OLD.family_id IS DISTINCT FROM NEW.family_id THEN
        DELETE FROM circle_members WHERE circle_id = OLD.family_id AND user_id = NEW.id;
    END IF;
    IF NEW.family_id IS NOT NULL THEN
        -- Self-heal: recreate the circle if it was deleted while the family lives.
        INSERT INTO circles (id, name, created_at)
        SELECT f.id, f.name, f.created_at FROM families f WHERE f.id = NEW.family_id
        ON CONFLICT (id) DO NOTHING;
        INSERT INTO circle_members (circle_id, user_id, role)
        VALUES (NEW.family_id, NEW.id, CASE WHEN NEW.role = 'admin' THEN 'admin' ELSE 'member' END)
        ON CONFLICT (circle_id, user_id) DO UPDATE SET role = EXCLUDED.role;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_circle_members_user ON users;
CREATE TRIGGER trg_circle_members_user AFTER INSERT OR UPDATE OF family_id, role ON users
    FOR EACH ROW EXECUTE FUNCTION circle_members_sync_from_user();
