# Operator privacy controls

## Platform admin access to live location (SEC-007)

A platform admin manages accounts and servers; by default they **cannot see
where anyone is**. `ADMIN_LOCATION_ACCESS` (default `true`; set `false` to hide member locations from admins) controls this:

| Surface | Default (`false`) | `true` |
|---|---|---|
| `GET /api/admin/members`, `/families/{id}/members` | members listed, all position fields omitted | positions included |
| `GET /api/admin/members/{id}/history` and `/history/export` | `403` | allowed |
| `GET /api/admin/activity` | `lat`/`lon` omitted | included |
| `GET /api/admin/ws` | socket opens (avatar updates only); snapshot redacted; no location, presence or alert frames | full live stream |

Every denied attempt writes an `admin.location_denied` audit row; every
permitted read writes an `admin.location_view` row carrying the viewed family so
that family's admins see it in `GET /audit`. Repeated identical reads inside a
minute collapse into one row. Tests: `handlers/admin_location_policy_test.go`,
`handlers/audit_view_test.go`.

## Location history retention

`LOCATION_RETENTION_DAYS` (default 90, in `docker-compose.yml` / `.env`) sets
the TimescaleDB retention policy on the `locations` hypertable at startup and
caps what history endpoints will serve. It is the only place the number lives.

Each user can additionally choose a **shorter** personal window and erase their
own history (the trail belongs to the person, so it applies to every circle they
are in; per-circle windows are intentionally not modelled):

- `GET /me/location-retention` -> `{"days": 30|null, "max_days": 90}`
- `PUT /me/location-retention {"days": 30}` (1..max, `null` = deployment default);
  applied immediately and enforced hourly (`RunUserRetention`). Migration 000130.
- `DELETE /me/locations[?before=RFC3339]` erases stored points (rows are removed
  from the hypertable); without `before` the last known position is cleared too.
- `GET /me/export` downloads all of the caller's own data.

Retention in TimescaleDB is chunk-granular for the global policy, so rows can
outlive the window by up to one chunk; personal windows delete exact rows.
Backups are outside this policy.

## WebSocket origin (SEC-009)

`/ws/stream` and `/api/admin/ws` authenticate with a Bearer header or the
`Sec-WebSocket-Protocol` token, never a cookie or query string. On top of that
the handshake enforces an Origin policy:

- `ALLOWED_ORIGIN` empty: same origin only (the Origin host must equal the
  request Host); every foreign browser origin is rejected with 403.
- `ALLOWED_ORIGIN=https://app.example.com`: that origin is also accepted.
- No `Origin` header (native Android/iOS clients): accepted; there is no ambient
  credential for a cross-site page to ride.

Tests: `handlers/ws_origin_test.go`.

## Geofence accuracy filtering

See `docs/geofencing.md`.
