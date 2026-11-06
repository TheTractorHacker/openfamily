# Operator privacy controls

## Platform admin access to live location (SEC-007)

A platform admin manages accounts and servers; by default they **cannot see
where anyone is**. `ADMIN_LOCATION_ACCESS` (default `false`; set `true` to let platform admins see member locations) controls this:

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

## Private (end-to-end encrypted) circles and admin access

For a Private circle the server holds ciphertext only, so `ADMIN_LOCATION_ACCESS`
neither grants nor needs to deny anything there: the admin endpoints have no
plaintext to return, and nothing was changed in that policy. A platform admin can
read a Private circle only as a **member**: their own account must be in the
circle, and a browser (admin web "Private circles" page) or bridge key of theirs
must have been approved by their own phone and given the circle key by a member's
phone. The server cannot grant or fake this (it holds no key and cannot produce
the required phone signatures). Approved viewers and bridges are listed per
account on the admin "Encryption keys" page (kind, fingerprint, created) and are
entries in the key transparency log. A browser viewer decrypts with JavaScript
served by this server, so an operator who modifies the web app could read what a
logged-in member's viewer shows; see `docs/design/E2EE.md` ("Threat model of the
web viewer"). Use the phone app if that matters.

### Trusted-server mode

If the owner enabled the optional trusted-server mode and **every member of a
Private circle** allowed it on their phone, that circle is readable by the server:
positions are ingested into the normal tables and the circle is treated like a
normal circle for visibility (`e2ee_server_member`, derived from the phones'
signed consents, never a toggle). `ADMIN_LOCATION_ACCESS` then governs it exactly
like any normal circle (default `deny`; `family_admin` or `all` as you set it);
nothing about that policy changed. The admin map shows only the positions the
server decrypted, and every admin read is audited as before. A circle without an
approved server device stays sealed and invisible to the admin map. Members can
withdraw consent and delete the server's copies in the app (`Encryption keys >
circle > Trusted server`); a circle admin can delete all copies
(`DELETE /circles/{id}/e2ee/server-copies?scope=circle`). Retention
(`LOCATION_RETENTION_DAYS` and each person's window) applies to the copies.

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
