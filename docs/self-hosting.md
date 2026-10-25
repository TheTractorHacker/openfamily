# Self-hosting OpenFamily

Production checklist for operators. The README [Quick start](../README.md#quick-start)
is enough for a laptop. Use this before you invite a family onto a VPS or NAS
that is reachable from the internet.

## Before `docker compose up`

```bash
./scripts/setup.sh
```

This writes `.env` (never overwriting an existing one) with a random
`POSTGRES_PASSWORD`, `JWT_SECRET` and first-admin password, and asks for your
`SITE_ADDRESS` and `PLATFORM_ADMIN_EMAIL`. Compose refuses to start if
`POSTGRES_PASSWORD` or `JWT_SECRET` is unset; there are no default passwords.
Doing it by hand instead: copy `.env.example` to `.env` and set

1. `JWT_SECRET` (at least 32 random bytes, `openssl rand -hex 32`) and
   `POSTGRES_PASSWORD` (use a hex/alphanumeric value; it is embedded in a URL).
2. `SITE_ADDRESS=openfamily.example.com` and `COMPOSE_PROFILES=proxy` so Caddy
   requests a certificate.
3. `APP_ENV=production` and `DB_SSL_DISABLE_OK=true` (see Database TLS below).
4. `PLATFORM_ADMIN_EMAIL` and `PLATFORM_ADMIN_PASSWORD`. This creates the
   first admin and **closes open registration** (invite codes required).

## Optional components (compose profiles)

| Profile | Service | Enable when |
|---|---|---|
| *(none)* | `api`, `postgres` | Always. The API is published on `127.0.0.1:8080` only. |
| `proxy` | `caddy` | You want HTTPS on a domain without bringing your own reverse proxy. |
| `push` | `ntfy` | You want Android push (UnifiedPush) hosted by you. |

Enable with `COMPOSE_PROFILES=proxy,push` in `.env` or
`docker compose --profile proxy up -d`. Without `proxy`, put your own TLS
reverse proxy in front of `127.0.0.1:8080` (the API trusts it because
`TLS_BEHIND_PROXY=true`). All images are pinned to explicit versions; services
drop all Linux capabilities, use `no-new-privileges`, and have CPU/memory
limits (edit `deploy.resources.limits` in `docker-compose.yml` for small or
large hosts). The Caddyfiles set HSTS, `X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy` and `Permissions-Policy` headers (no CSP,
to avoid breaking the admin panel).

## Database TLS

`APP_ENV=production` makes the API reject `sslmode=disable`, `prefer`, `allow`
and a missing `sslmode`. The bundled Postgres is reachable only on the private
Compose network and has no TLS configured, so `setup.sh` sets
`DB_SSL_DISABLE_OK=true` for production installs. If Postgres runs elsewhere or
is published, set `DATABASE_URL=...?sslmode=verify-full`, leave
`DB_SSL_DISABLE_OK` unset, and configure server certificates on Postgres. In
`APP_ENV=development` (the default) nothing is enforced.

## Upgrades and backups

```bash
./scripts/backup.sh                      # ./backups/openfamily-<UTC time>.dump (BACKUP_KEEP=N prunes)
./scripts/restore.sh backups/<file>.dump # DESTRUCTIVE; asks you to type RESTORE
./scripts/upgrade.sh                     # backup, pull, rebuild, wait for /healthz, roll back on failure
```

`upgrade.sh` refuses to run with uncommitted changes, writes
`backups/pre-upgrade-*.dump`, runs `git pull --ff-only`, `docker compose up -d
--build`, and polls `/healthz` (`HEALTH_TIMEOUT`, default 120s). On failure it
checks out the previous git ref, rebuilds, and prints the `restore.sh` command
for the pre-upgrade dump, since migrations that already ran are not undone by a
code rollback. There is no in-app updater and no Docker socket access. Schedule
`backup.sh` from cron and copy `backups/` off the host.

Step 5 in detail — DNS records, certificate behavior, and troubleshooting — is
covered in [custom-domain.md](custom-domain.md). The admin panel's
**Settings → Custom domain** card runs live DNS and HTTPS checks against your
setup.

## Android push (ntfy)

Do **not** publish ntfy on `0.0.0.0:2586`. Compose binds loopback only, and the service only exists with the `push` profile.

For phones on the public internet:

```bash
COMPOSE_PROFILES=proxy,push
PUSH_ADDRESS=push.example.com
NTFY_BASE_URL=https://push.example.com
CADDYFILE=Caddyfile.with-push
```

Install the [ntfy Android app](https://ntfy.sh/) on each phone. UnifiedPush
registration is silent; if alerts never arrive, ntfy is usually missing.

## Map tiles

Default street tiles are public OSM; satellite is Esri. Those hosts see the
viewport. To use another raster provider (API key goes in the URL):

```bash
TILE_URL=https://tiles.example.com/{z}/{x}/{y}.png?api_key=xxx
SATELLITE_TILE_URL=
```

The API returns these on `GET /config`. The generic APK does not need a rebuild.
A key in `TILE_URL` is visible to every phone.

## Optional SMS

Set `TWILIO_*` and `PUBLIC_BASE_URL=https://openfamily.example.com` so SOS
messages carry a share link instead of raw coordinates. The same values can
be saved on the admin **Settings** page; a saved row overrides empty env
values without restarting. Emergency contacts appear in the app only when
SMS is configured.

## Backups and disk encryption

- Volume `pgdata` is the family database. Use `./scripts/backup.sh` (above) on a schedule and keep copies off the host.
- Enable host disk encryption (LUKS, Synology volume encryption, cloud disk
  encryption). The app does not encrypt rows itself.
- Keep `app/android/upload-keystore.jks` (or CI signing secrets) backed up.
  Losing the keystore forces every phone to uninstall before they can update.

## Family setup (give this to members)

1. Install the Android APK from the admin **Builds** page (or the GitHub
   Release).
2. Enter `https://openfamily.example.com` and Connect.
3. Create an account (invite code if the server requires one).
4. Allow **Always** location, notifications, and the battery exemption.
5. Install **ntfy** so alerts arrive when the app is closed.
