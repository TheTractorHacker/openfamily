-- Restore the 000220 purge function (without charging), then drop the columns.
CREATE OR REPLACE FUNCTION e2ee_purge_user_server_copies(circ UUID, usr UUID) RETURNS VOID AS $$
DECLARE
    tss TIMESTAMPTZ[];
BEGIN
    -- Serialise with ingest: ingest holds this circle row FOR SHARE for its whole
    -- batch, so a purge waits for an in-flight batch to commit and then removes what
    -- it wrote; an ingest that starts later waits for this transaction and then sees
    -- the member's lane gone. Lock order everywhere: circles (by id) before anything else.
    PERFORM 1 FROM circles WHERE id = circ FOR UPDATE;
    WITH del AS (
        DELETE FROM locations l USING devices d
         WHERE d.id = l.device_id AND d.user_id = usr AND l.e2ee_circle_id = circ
        RETURNING l.ts)
    SELECT array_agg(ts) INTO tss FROM del;
    IF tss IS NOT NULL THEN
        UPDATE member_positions mp SET lat = n.lat, lon = n.lon, ts = n.ts, device_id = n.device_id,
               accuracy_meters = n.acc, speed_mps = n.spd, battery_pct = n.bat, heading_deg = NULL, motion_state = NULL
          FROM (SELECT ST_Y(l.geom) AS lat, ST_X(l.geom) AS lon, l.ts, l.device_id, l.accuracy_meters AS acc,
                       l.speed_mps AS spd, l.battery_pct AS bat
                  FROM locations l JOIN devices d ON d.id = l.device_id
                 WHERE d.user_id = usr AND (l.e2ee_circle_id IS NULL OR e2ee_member_server_ok(l.e2ee_circle_id, usr))
                 ORDER BY l.ts DESC LIMIT 1) n
         WHERE mp.user_id = usr AND mp.ts = ANY (tss);
        -- no other location remains: a last position that was one of the purged points goes
        DELETE FROM member_positions WHERE user_id = usr AND ts = ANY (tss);
    END IF;
    -- Every server-line item of ANY purpose the member authored is readable by the
    -- server under SK (check-ins and events carry positions, places and chats carry
    -- place and message data): all of them go. Phones keep what they already pulled;
    -- members who had not pulled them yet lose them.
    DELETE FROM e2ee_items i USING device_keys k
     WHERE i.circle_id = circ AND i.key_line = 'server'
       AND k.device_id = i.device_id AND k.user_id = usr;
END $$ LANGUAGE plpgsql;

ALTER TABLE member_positions DROP COLUMN IF EXISTS charging;
ALTER TABLE locations DROP COLUMN IF EXISTS charging;
