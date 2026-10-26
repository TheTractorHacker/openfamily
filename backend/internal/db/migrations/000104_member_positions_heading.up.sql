-- 000104: expose heading on the live path. locations.heading_deg already
-- exists; member_positions (last-known position) now carries it too so the
-- members snapshot and WS location frames can orient/interpolate the pin.
ALTER TABLE member_positions ADD COLUMN IF NOT EXISTS heading_deg double precision;
