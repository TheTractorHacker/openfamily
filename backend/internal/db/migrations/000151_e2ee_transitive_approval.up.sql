-- 000151_e2ee_transitive_approval.up.sql
-- A key may receive circle key wraps in a circle only when its registration
-- chain (registered_by_device_id -> ... -> root) contains a key that is the
-- user's FIRST key ever (`initial`) or that a circle admin approved for that
-- circle. A key cross-signed or rotated by an unapproved key therefore stays
-- unapproved. Revoked ancestors keep counting (their rows are never deleted).
-- Idempotent.
CREATE OR REPLACE FUNCTION e2ee_device_approved(dev UUID, circ UUID) RETURNS BOOLEAN AS $$
    WITH RECURSIVE chain(device_id, parent, initial, depth) AS (
        SELECT device_id, registered_by_device_id, initial, 0
          FROM device_keys WHERE device_id = dev
        UNION
        SELECT k.device_id, k.registered_by_device_id, k.initial, c.depth + 1
          FROM chain c
          JOIN device_keys k ON k.device_id = c.parent AND c.parent <> c.device_id
         WHERE c.depth < 32
    )
    SELECT COALESCE(bool_or(
        c.initial OR EXISTS (SELECT 1 FROM device_approvals a
                              WHERE a.device_id = c.device_id AND a.circle_id = circ)
    ), FALSE) FROM chain c
$$ LANGUAGE sql STABLE;
