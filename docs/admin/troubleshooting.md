# Troubleshooting

Start with `docker compose ps` (all services "healthy"/"running"),
`curl http://localhost:8080/healthz` and `docker compose logs --tail 100 api`.
The admin **System** page lists recent warnings and errors.

## Nobody shows on the map

Work down this list; most cases end at step 2 or 3.

1. **Is the server reachable from the phone?** Open the server address in the
   phone's browser. If it fails, fix DNS, ports 80/443 or the VPN first
   ([HTTPS and domain](https-and-domain.md)).
2. **Is the phone allowed to report?** Location "All the time", battery
   Unrestricted ([Battery and permissions](../user/battery-and-permissions.md)).
   The admin **Fleet** page shows the last time each phone reported.
3. **Is the person sharing?** Check the circle's "Share my location" and that
   they have not paused sharing.
4. **Do you use a Private circle?** The admin web cannot show a Private circle
   unless you are a member who approved the browser. Positions are sealed
   ([Privacy modes explained](../user/privacy-modes.md)).
5. **Can an admin look at members?** The admin map is empty by design unless
   `ADMIN_LOCATION_ACCESS=true`.
6. **Is the app too old?** Check [App versions](app-versions.md): with
   enforcement on, an unsupported app's uploads are refused.
7. **Map tiles missing but people listed?** The tile provider is unreachable;
   see "Map tiles" in [Self-hosting](../self-hosting.md#map-tiles).

A fuller step-by-step: [No locations](../troubleshooting/no-locations.md).

## Alerts do not arrive

See [Notifications](notifications.md) and [Push](../push.md). Check ntfy is
installed, and that Android is not putting the app to sleep.

## Admin web says "Access denied"

Only platform admins see admin pages. If `REQUIRE_ADMIN_MFA=true`, turn on
two-step sign-in in the app, sign out and in again.

## The server will not start

`docker compose run --rm api validate-config` prints what is wrong without
revealing secrets. Common causes: `JWT_SECRET` or `POSTGRES_PASSWORD` unset,
a database TLS setting ([Self-hosting](../self-hosting.md#database-tls)).

## After an update something is off

`./scripts/upgrade.sh` rolls back on failure. Otherwise restore the
`backups/pre-upgrade-*.dump` ([Backups](backups.md)).

## Still stuck

Open an issue at https://github.com/TheTractorHacker/openfamily/issues with the
server version (admin web footer) and the last lines of `docker compose logs api`.
Remove addresses and secrets first.
