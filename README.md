<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/openfamily/openfamily-logo-horizontal-dark.svg">
    <img src="assets/brand/openfamily/openfamily-logo-horizontal.svg" alt="OpenFamily" width="560">
  </picture>
</p>

<h1 align="center">OpenFamily</h1>

<p align="center">
  <strong>A self-hosted family GPS locator.</strong> You run the server.
  Your family's location never leaves it.<br>
  Life360-style live map, SOS, places, and history — not a calendar or shopping app.<br>
  <a href="https://openfamily.app">openfamily.app</a>
  ·
  <a href="https://openfamily.app/compare/">Compare</a>
  ·
  <a href="https://openfamily.app/quick-start/">Quick start</a>
</p>

[![Go](https://img.shields.io/badge/Go-1.25-00ADD8?logo=go&logoColor=white)](https://go.dev/)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev/)
[![OpenStreetMap](https://img.shields.io/badge/Maps-OpenStreetMap-7EBC6F?logo=openstreetmap&logoColor=white)](https://www.openstreetmap.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-PostGIS%20%2B%20TimescaleDB-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org/)

OpenFamily is an open-source alternative to commercial family locators
(a self-hosted Life360 alternative). A Flutter app for Android and iOS talks
to a Go API you host with Docker — on a VPS, a Synology NAS, or a machine on
your LAN. There is no vendor cloud, no analytics SDK, and no Google Play
Services requirement on Android.

This repository is a **family GPS location tracker**. It is not
[NexaFlowFrance/OpenFamily](https://github.com/NexaFlowFrance/OpenFamily), a
different product: a self-hosted family **organizer** (calendar, shopping,
chores) that currently ranks first in GitHub search for the same name.

![OpenFamily — keep your family close without giving up your privacy](assets/brand/openfamily/openfamily-social-card.png)

```
┌──────────┐   ┌──────────┐   ┌──────────────────────────────┐
│  Caddy   │──▶│  Go API  │──▶│  PostgreSQL + PostGIS        │
│  (TLS)   │   │ (REST+WS)│   │  + TimescaleDB (history)     │
└──────────┘   └────┬─────┘   └──────────────────────────────┘
                    │
              ┌─────▼─────┐
              │   ntfy    │  Android UnifiedPush — no Google
              └───────────┘
```

## Table of contents

- [Why self-host this](#why-self-host-this)
- [Features](#features)
- [Compared to](#compared-to)
- [Quick start](#quick-start)
- [Family setup](#family-setup)
- [Mobile apps](#mobile-apps)
- [Web admin panel](#web-admin-panel)
- [Self-hosting map tiles](#self-hosting-map-tiles)
- [Run on a Synology NAS](#run-on-a-synology-nas)
- [Configuration](#configuration)
- [Security](#security)
- [API reference](#api-reference)
- [Development](#development)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Why self-host this

Commercial family trackers send live coordinates to someone else's cloud and
monetize the result. OpenFamily is the opposite posture:

- **You own the data.** Locations, places, and history live in your Postgres.
- **Android push is self-hosted.** [UnifiedPush](https://unifiedpush.org/) via
  [ntfy](https://ntfy.sh/) — no Firebase, no Google account on the phone.
- **Maps are OpenStreetMap, not Google.** The app renders OSM tiles with
  [flutter_map](https://docs.fleaflet.dev/); the admin panel uses
  [Leaflet](https://leafletjs.com/). There is no Google Maps SDK and no
  Google Places. Named places live in your Postgres. Point the app at your
  own tile server so pan/zoom does not even hit the public OSM or Esri
  endpoints.
- **iOS push is honest.** Apple requires APNs. Payloads carry no coordinates;
  the app fetches the real content from *your* server over TLS.

This is a family app, not a fleet tracker. It is built for a handful of people
who share a home, not for vehicles, tools, or public sharing.

## Features

### Live map

- Full-bleed **OpenStreetMap**, updated over a WebSocket —
  [flutter_map](https://docs.fleaflet.dev/) on the phone,
  [Leaflet](https://leafletjs.com/) in the admin panel. No Google Maps, no
  Mapbox, no Google Places
- Member bubbles with photo avatars, per-person color rings, battery, and
  last-seen time
- Status rings for live, low battery, GPS trouble, stopped, and error
- Driving and cycling badges on the live map; Home / Work / Gym on the
  history timeline
- Zoom-aware clustering with tap-to-fan-out when people overlap
- Street (OSM) and optional satellite layers
- Approximate-location zone when GPS accuracy is poor
- A dedicated **People** roster (live status, invite, tap through to a
  member profile)

### Places and geofences

- Named places you save (Home, School, Work, Gym, or custom) — stored on
  your server, not looked up from Google Places
- Per-place radius and arrive / leave alerts
- Server-side geofencing with a 60-second debounce so jitter at the boundary
  does not spam notifications
- Role-gated: children can see places, only admins and members can edit them
- Save a place by dropping a pin on the map

### Safety

- **SOS** — tap to send, or press-and-hold for a discreet 10-second countdown
  with slide-to-cancel; practice mode; “I'm safe” follow-up
- **Help** — a non-emergency ping to the family only (no emergency contacts)
- **Check in** — “I'm here” with an optional note
- Emergency contacts who receive SOS even without the app (shown only when SMS is configured)
- Optional Twilio SMS from admin Settings or `TWILIO_*`; in-app push and WebSocket still work without it
- A public 24-hour share page for an alert (token in the SMS, no login)

### History

- Per-member day view: map trail plus a visit timeline
- Named place stays, unnamed dwells, and in-transit segments
- Save an unnamed stop as a family place
- 90-day retention (TimescaleDB); last-known position is kept so inactive
  members stay on the map

### Families and accounts

- Create a family or join with an invite code
- Roles: **admin**, **member**, **child**
- Invite codes (8-character, Crockford alphabet, default 7-day / single-use)
- Rename the family, change roles, leave (last admin cannot leave)
- Profile name, phone, and a private avatar (never a public URL)
- Location-sharing toggle: this device stops reporting when you turn it off
- Optional biometric unlock (Face ID / Touch ID / Android biometrics) on
  cold start and return-to-foreground

### Push and background location

- Android: foreground service with a persistent notification; restarts after
  reboot; battery-optimization exemption prompt so OEM killers do not stale
  the fix
- iOS: `location` background mode
- Tracking starts after login and stops on logout
- ntfy / UnifiedPush on Android; APNs on iOS
- One generic APK for every deployment — first launch asks for the server URL

### Web admin panel

Served by the API at `/admin` (embedded in the Go binary). A **platform
admin** — distinct from a family admin — can:

- Watch a live map of every family and member
- Browse per-member day history
- Create, rename, and delete families; move people between them
- Manage every account (including people with no family): create users,
  assign families, change roles, reset passwords
- Generate invite codes for any family
- Download the Android APK
- Jump with a ⌘K command menu

Setting `PLATFORM_ADMIN_EMAIL` also **closes open registration**: new users
need a valid invite code.

## Compared to

On-site write-up: [openfamily.app/compare](https://openfamily.app/compare/).

| | OpenFamily | Life360-class apps | [OwnTracks](https://owntracks.org/) | [Traccar](https://www.traccar.org/) | [Dawarich](https://dawarich.app/) |
|---|---|---|---|---|---|
| Self-hosted | Yes | No | Yes | Yes | Yes |
| Family map + SOS | Yes | Yes | No | Weak | No |
| Geofence UI | Yes | Yes | Limited | Yes (fleet) | No |
| Location history | 90-day trail | Vendor cloud | Recorder | Yes | Timeline-first |
| Android without Google | UnifiedPush / ntfy | FCM | MQTT | Optional | N/A |
| Built for | Families | Families (cloud) | Recorders | Fleets | Personal timeline |

## Quick start

### Prerequisites

- Docker and Docker Compose
- Go 1.25+ only if you run the API outside Docker
- Flutter 3.x only if you build the app yourself

### 1. Start the stack

```bash
./scripts/setup.sh && docker compose up -d
```

`setup.sh` writes `.env` with random database, JWT and admin passwords (it never
overwrites an existing `.env`) and asks for your domain and admin email. A
domain turns on the `proxy` profile (Caddy with automatic HTTPS); with `:80`
the API listens on `http://localhost:8080` only. Optional pieces are compose
profiles: `proxy` (Caddy) and `push` (ntfy). See
[docs/self-hosting.md](docs/self-hosting.md).

Existing deployments should retain their current `DATABASE_URL`,
`POSTGRES_USER`, and `POSTGRES_DB` values during the upgrade. The OpenFamily
database defaults are for fresh installations and do not rename stored data.

```bash
curl http://localhost:8080/healthz   # or https://your-domain/healthz
# {"status":"ok"}
```

### 2. Create an account

```bash
curl -X POST http://localhost:8080/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"supersecret1","name":"Alice"}'

curl -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"supersecret1"}'
```

For a managed server (invite-only registration and the admin panel), set
`PLATFORM_ADMIN_EMAIL` and `PLATFORM_ADMIN_PASSWORD` in `.env` before the
first start. See [Web admin panel](#web-admin-panel).

### 3. Point the app at your server

Install the APK from the admin panel's **APK** page, or run from source
(see [Mobile apps](#mobile-apps)). On first launch, enter the server URL
if it was not baked in at build time.

Public internet deployments: follow [docs/self-hosting.md](docs/self-hosting.md)
before you invite anyone.

## Family setup

1. Install the Android APK (admin **Builds** page or the latest GitHub Release).
2. Enter your server URL (for example `https://openfamily.example.com`).
3. Create or join a family (invite code if the operator closed registration).
4. Allow **Always** location and notifications. On Android, grant the battery
   exemption under Settings → Background updates.
5. Install [ntfy](https://ntfy.sh/) so SOS, geofence, and check-in alerts
   arrive when OpenFamily is closed.

Privacy details: [PRIVACY.md](PRIVACY.md) ([on the site](https://openfamily.app/privacy/)).
Operator hardening: [docs/self-hosting.md](docs/self-hosting.md)
([on the site](https://openfamily.app/docs/)).

## Mobile apps

The Flutter app (`app/`) covers Android and iOS: onboarding, the live map,
places, safety, history, and foreground + background location reporting.

```bash
cd app
flutter create .        # generates missing platform scaffolding
flutter pub get
flutter run --dart-define=OPENFAMILY_API_URL=http://localhost:8080
```

| Target | `OPENFAMILY_API_URL` |
|---|---|
| iOS simulator | `http://localhost:8080` |
| Android emulator | `http://10.0.2.2:8080` (host loopback from inside the emulator) |
| Physical device | `http://<your-LAN-IP>:8080` (e.g. `http://192.168.1.20:8080`) |

A release APK does not need a dart-define. If the URL is unset, the app
shows a server-config screen and stores the origin you type.

### Map tiles

The map is **OpenStreetMap** throughout. The phone uses
[flutter_map](https://docs.fleaflet.dev/); the admin panel uses
[Leaflet](https://leafletjs.com/). Neither Google Maps nor Google Places is
in the stack.

By default the street layer is the public OSM tile server. The optional
satellite layer defaults to Esri World Imagery (still not Google). Both
receive the map viewport on every pan/zoom.

Operators override that without rebuilding the APK by setting `TILE_URL` and
`SATELLITE_TILE_URL` in `.env`; the server returns both on `GET /config`.
Templates use `{z}` / `{x}` / `{y}` (the ArcGIS-style satellite template
swaps `{y}` / `{x}`). See [docs/self-hosting.md](docs/self-hosting.md).

### Background location

Tracking uses a vendored, patched
[`background_locator_2`](https://pub.dev/packages/background_locator_2)
(upstream is unmaintained; the copy in `app/packages/` drops jcenter and
builds on Gradle 8).

- **Android:** a foreground service keeps reporting when the app is
  backgrounded or killed, and after reboot. Settings → **Background updates**
  opens the battery-optimization exemption screen — needed on many OEMs.
- **iOS:** the `location` background mode keeps updates flowing while
  backgrounded. “Always” authorization is required.
- Credentials are mirrored to `shared_preferences` so the background isolate
  (which cannot reach secure storage) can authenticate. See [Security](#security).

### Push

- **Android:** install [ntfy](https://ntfy.sh/) (or another UnifiedPush
  distributor). The API advertises `NTFY_BASE_URL` on `GET /config` so the
  generic APK can register without a rebuild.
- **iOS:** APNs. Requires an Apple Developer account and an auth key — see
  [Configuration](#configuration). Payloads do not include coordinates.

## Web admin panel

The backend serves the panel at `/admin`. The Vite + React + Leaflet SPA is
embedded with `go:embed`; no separate web server.

### Grant platform-admin access

Platform admin is a per-user flag (`users.platform_admin`), not family admin.
There is no self-service signup for it.

1. Set `PLATFORM_ADMIN_EMAIL` and `PLATFORM_ADMIN_PASSWORD` in `.env`.
2. Start the API. On startup it creates that account if needed, marks it
   `platform_admin`, and creates a family for it. If the account already
   exists, it is promoted (idempotent — safe to leave set).

Setting `PLATFORM_ADMIN_EMAIL` **closes open registration**.

### Use it

1. `docker compose up -d --build` and open `https://<your-host>/admin`.
2. Log in with the platform-admin account (same `/auth/login` flow, including
   TOTP if enabled on the account).
3. **Dashboard** — live map of every family (color rings, status dots,
   movement badges, Home / School / Work pins) over `/api/admin/ws`.
   **History** — one day's trail and visits for any member.
   **Families** — create / rename / delete, move members, invite codes.
   **Users** — every account, including people with no family; create,
   assign, change role, reset password.
   **APK** — download the Android APK.
   **Settings** — your account (name, password, photo), this server, and
   the running server version (upgrade with `./scripts/upgrade.sh`, see
   [Updating the server](#updating-the-server)).

### Invite codes

When registration is closed, a new user must present a valid invite. Each
code is bound to a family and role (admin / member / child), default 7-day
expiry, single use.

Codes are 8-character strings from a Crockford-style alphabet (ambiguous
`0`/`O` and `1`/`I`/`L` removed). They are case-insensitive and tolerate
spaces and dashes (`ab12-cd34` matches `AB12CD34`).

- Family admins generate codes in the app (`POST /family/invites`).
- Platform admins generate codes for any family from **Families**.
- Register with `invite_code`, or join later with `POST /family/join`.

### APK builds

The server does **not** build APKs. CI
([`.github/workflows/apk.yml`](.github/workflows/apk.yml)) builds a signed
release APK on merge to `main` (when `app/` changes) and publishes it as a
GitHub Release tagged `apk-<run_number>` for testers. Those CI tags are not
GitHub Latest.

The admin **Download** button follows the latest user-facing `v*` semver
GitHub Release that has an `.apk` asset (for example `v0.1.0`) and caches
it in `APK_DIR`. It does not use the `apk-*` firehose.

Public GitHub Releases do not need a token. Set `APK_GITHUB_TOKEN` in
`.env` only if you fetch from a private fork or hit GitHub's
unauthenticated rate limit, then recreate the API container.

Release APKs are signed with a dedicated upload keystore so Android can
install each new build as an in-place update. CI requires these repository
secrets:

- `ANDROID_KEYSTORE_BASE64` — base64-encoded `upload-keystore.jks`
- `ANDROID_KEYSTORE_PASSWORD` — keystore and key password
- `ANDROID_KEY_ALIAS` — key alias (`upload`)

`versionCode` is the workflow `run_number` (`flutter build apk --build-number`).
Bump `version:` in `app/pubspec.yaml` only when you want the user-visible
`versionName` to change.

Keep a backup of `app/android/upload-keystore.jks` and
`app/android/key.properties` (both gitignored). Losing the keystore means
users have to uninstall before they can install a newly signed APK.

One generic APK works for every deployment because of the runtime server URL
screen.

### Updating the server

The server does not update itself and nothing in the stack has access to the
Docker socket. Upgrade from a shell on the host:

```bash
./scripts/upgrade.sh
```

It refuses to run with uncommitted changes, backs up the database to
`./backups`, pulls, rebuilds, waits for `/healthz`, and rolls the code back
(printing the restore command) if the new version does not come up. See
[docs/self-hosting.md](docs/self-hosting.md#upgrades-and-backups).

## Self-hosting map tiles

For a fully private map, host your own tiles. The simplest option is
[tileserver-gl](https://github.com/maptiler/tileserver-gl):

1. Download an OSM extract for your region from
   [Geofabrik](https://download.geofabrik.de/) or
   [Protomaps](https://docs.protomaps.com/).
2. Add a tileserver service:

   ```yaml
   tiles:
     image: maptiler/tileserver-gl:latest
     restart: unless-stopped
     volumes:
       - ./tiles/data.mbtiles:/data/data.mbtiles:ro
     expose:
       - "80"
   ```

3. Reverse-proxy it with Caddy:

   ```
   tiles.example.com {
       reverse_proxy tiles:80
   }
   ```

4. Set `TILE_URL` (and optionally `SATELLITE_TILE_URL`) to your proxied tile
   template, then reload the stack. The app receives it from `GET /config`.

## Run on a Synology NAS

1. **Requirements:** an x86_64 model with **Container Manager** (Docker) and
   **4 GB+ RAM** (Postgres + TimescaleDB is the main consumer).
2. Copy this repo to the NAS (`git clone` or a shared folder).
3. In Container Manager → **Project**, point at `docker-compose.yml`, or SSH:

   ```bash
   cd /path/to/openfamily
   cp .env.example .env   # set strong secrets
   docker compose up -d --build
   ```

4. **Storage:** the `pgdata` volume holds all data. Put it on a volume with
   snapshots, and schedule `pg_dump`.
5. **Remote access:** do **not** expose ports publicly if you can avoid it.
   Use Tailscale or WireGuard, then set
   `SITE_ADDRESS=openfamily.<your-tailnet>.ts.net` so Caddy gets a real
   certificate. For a public domain, set `SITE_ADDRESS=openfamily.example.com`
   and open 80/443.
6. **ntfy / UnifiedPush:** set `PUSH_ADDRESS` and `NTFY_BASE_URL` so Android
   push works over TLS. `PUSH_ADDRESS` alone does not enable TLS — add a
   Caddy site block for ntfy (commented example in `caddy/Caddyfile`).
   Install the [ntfy Android app](https://ntfy.sh/) on family devices.

## Configuration

### Backend

| Variable | Default | Purpose |
|---|---|---|
| `HTTP_ADDR` | `:8080` | API listen address |
| `DATABASE_URL` | local dev URL | PostgreSQL connection string |
| `POSTGRES_USER` / `POSTGRES_DB` | `openfamily` | Database identity for fresh Compose installs |
| `JWT_SECRET` | `change-me-in-production` | JWT signing secret (**set this**) |
| `ACCESS_TOKEN_TTL` | `15m` | Access token lifetime |
| `REFRESH_TOKEN_TTL` | `720h` | Refresh token lifetime |
| `ALLOWED_ORIGIN` | *(empty)* | CORS origin |
| `APP_ENV` | `development` | `production` fails fast on insecure defaults (incl. Postgres `sslmode`) |
| `DB_SSL_DISABLE_OK` | `false` | Allow `sslmode=disable` in production (Postgres only on the private Docker network) |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | *(empty)* | Direct HTTPS (Caddy is the usual path) |
| `TLS_BEHIND_PROXY` | `false` | `true` when a reverse proxy terminates TLS |
| `INSECURE_HTTP` | `false` | Opt-out of TLS (trusted private networks only) |
| `VERBOSE_PUSH` | `false` | Include the user's name in push payloads |
| `NTFY_BASE_URL` | *(empty)* | Public ntfy origin advertised on `GET /config` |
| `TILE_URL` | OSM public tiles | Street `{z}/{x}/{y}` template on `GET /config` |
| `SATELLITE_TILE_URL` | Esri public tiles | Satellite template on `GET /config` |
| `PLATFORM_ADMIN_EMAIL` | *(empty)* | First platform admin; also closes open registration |
| `PLATFORM_ADMIN_PASSWORD` | *(empty)* | Password for the auto-created admin account |
| `APNS_KEY_FILE` | *(empty)* | APNs `.p8` key (empty disables APNs) |
| `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_TOPIC` | *(empty)* | APNs identifiers |
| `APNS_PRODUCTION` | `false` | Use the APNs production endpoint |
| `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_FROM` | *(empty)* | Optional SMS; empty keeps alerts in-app |
| `PUBLIC_BASE_URL` | *(empty)* | HTTPS origin for SMS share links |
| `APK_DIR` | `/data/apk` | Directory that caches the GitHub Release APK |
| `APK_GITHUB_REPO` | *(empty)* | GitHub `owner/name` whose latest v* semver Release holds the APK |
| `APK_GITHUB_TOKEN` | *(empty)* | Optional PAT to fetch the APK (needed for a private fork; Contents: Read) |

### Flutter app (`--dart-define`)

| Variable | Default | Purpose |
|---|---|---|
| `OPENFAMILY_API_URL` | *(empty)* | Backend base URL (runtime screen if unset) |
| `OPENFAMILY_NOMINATIM_URL` | *(empty)* | Optional Nominatim endpoint for address search |
| `OPENFAMILY_APP_VERSION` | `0.1.0` | Version reported when registering this device |

## Security

- Passwords are hashed with **Argon2id**. TOTP is verified at login when
  enabled on the account.
- Access tokens are short-lived; refresh tokens rotate via `/auth/refresh`.
- Production (`APP_ENV=production`) refuses to boot on a default `JWT_SECRET`
  or an insecure `DATABASE_URL`.
- **Encryption at rest is yours to provide.** The app does not encrypt the
  database. Enable host disk encryption (LUKS, FileVault, Synology volume
  encryption) or PostgreSQL TDE so a stolen disk is not readable location
  data.
- **90-day location retention.** TimescaleDB drops history older than 90
  days; `member_positions` keeps the last-known point.
- **Audit log** of auth, role changes, location ingest, and place / geofence
  management (`GET /audit`, family admins).
- **No third-party location pipeline.** Self-hosted tiles and ntfy keep
  viewports and notifications off vendor servers. APNs is the iOS exception
  (platform vendor; no coordinates in the payload).
- **SMS is optional.** Twilio sees destination numbers and a short-lived
  share URL on *your* server — not live coordinates, unless
  `PUBLIC_BASE_URL` is missing or not public HTTPS, in which case the
  message falls back to lat/lon. Leave Twilio unset to keep alerts on push
  and WebSocket only.
- **Background credentials** live in `shared_preferences` so the background
  isolate can refresh tokens. Biometric unlock covers the interactive UI; it
  does not encrypt those credentials or stop opted-in background reporting.
  `android:allowBackup="false"` keeps them off cloud backup.
- **No end-to-end encryption of location.** The server must read coordinates
  to evaluate geofences, build history, and fan out the live map. That is a
  deliberate tradeoff, not an oversight.

## API reference

<details>
<summary>Family API</summary>

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | Health check |
| GET | `/config` | Public ntfy, tile URLs, and whether APNs / SMS are configured |
| POST | `/auth/register` | Create account |
| POST | `/auth/login` | Password + optional TOTP → token pair |
| POST | `/auth/refresh` | Rotate refresh token |
| GET | `/me` | Signed-in profile |
| PATCH | `/me` | Update display name and/or phone |
| PATCH | `/me/password` | Change password (requires current password) |
| GET | `/me/contacts` | List emergency contacts |
| POST | `/me/contacts` | Add an emergency contact |
| DELETE | `/me/contacts/{id}` | Remove an emergency contact |
| GET | `/api/profile` | Own profile and avatar metadata |
| GET | `/api/profile/avatar` | Private profile image |
| PUT | `/api/profile/avatar` | Upload PNG/JPEG (raw body, max 5 MiB) |
| DELETE | `/api/profile/avatar` | Remove profile image |
| GET | `/family/members/{id}/avatar` | Same-family member's private image |
| GET | `/family/members/{id}/history?from&to` | One day of trail + visits |
| POST | `/families` | Create a family (caller becomes admin) |
| GET | `/family` | Get your family |
| PATCH | `/family` | Rename (admin) |
| POST | `/family/leave` | Leave (last admin cannot) |
| GET | `/family/members` | List members |
| PATCH | `/family/members/{id}/role` | Change a member's role |
| POST | `/family/invites` | Create an invite code (admin) |
| POST | `/family/join` | Join by invite code |
| GET / POST | `/family/places` | List / create places |
| PATCH / DELETE | `/family/places/{id}` | Update / delete a place |
| GET / POST | `/family/geofences` | List / create geofences |
| PATCH / DELETE | `/family/geofences/{id}` | Update / delete a geofence |
| GET | `/audit` | Recent audit entries (admin) |
| POST | `/devices` | Register a device |
| GET | `/devices` | List your devices |
| PATCH | `/devices/{id}` | Attach or clear push / UnifiedPush endpoint |
| POST | `/locations` | Ingest a location point |
| POST | `/alerts/check-in` | Check in (WS + push + optional SMS) |
| POST | `/alerts/help` | Help alert (family only) |
| POST | `/alerts/sos` | SOS to family plus emergency contacts |
| POST | `/alerts/{id}/resolve` | I'm-safe follow-up (sender only) |
| GET | `/alerts/share/{token}` | Public 24h share page (no auth) |
| WS | `/ws/stream` | Live position stream (family-scoped) |

</details>

<details>
<summary>Platform-admin API</summary>

All routes require a platform admin. The SPA at `/admin` calls these under
`/api/admin/*`.

| Method | Path | Purpose |
|---|---|---|
| GET / POST | `/api/admin/families` | List / create families |
| PATCH / DELETE | `/api/admin/families/{id}` | Rename / delete a family |
| GET | `/api/admin/families/{id}/members` | List one family's members |
| GET | `/api/admin/members` | List every member |
| GET | `/api/admin/members/{id}/avatar` | Member's private image |
| GET | `/api/admin/members/{id}/history?from&to` | One day of history |
| PATCH | `/api/admin/members/{id}/family` | Move a member to another family |
| GET / POST | `/api/admin/users` | List / create accounts |
| PATCH | `/api/admin/users/{id}/family` | Assign or unassign a family |
| PATCH | `/api/admin/users/{id}/role` | Change family role |
| PATCH | `/api/admin/users/{id}/password` | Reset password |
| GET | `/api/admin/places` | Every saved place |
| GET / POST | `/api/admin/invites` | List / create invite codes |
| GET | `/api/admin/apk` | Download the latest Android APK (GitHub Release, cached in `APK_DIR`) |
| POST | `/api/admin/apk/build` | Optional on-server build (needs Flutter) |
| GET | `/api/admin/apk/status` | Poll that build |
| GET / PUT / DELETE | `/api/admin/settings/sms` | Twilio SMS settings (token never returned) |
| GET | `/api/admin/version` | Running server version (read-only) |
| WS | `/api/admin/ws` | Live positions across all families |

</details>

## Development

### Layout

```
├── backend/          Go API (REST + WebSocket, embedded admin SPA)
├── app/              Flutter app (Android + iOS)
├── web/              Admin panel source (Vite + React + Leaflet)
├── caddy/            Caddyfile
├── apk/              Cached GitHub Release APK
└── docker-compose.yml
```

Migrations live in `backend/internal/db/migrations/` and run automatically
at API startup.

### Run the API without Docker

```bash
cd backend
go build -o server ./cmd/server
DATABASE_URL="postgres://openfamily:openfamily@localhost:5432/openfamily?sslmode=disable" \
JWT_SECRET="$(openssl rand -base64 48)" \
./server
```

### Rebuild the admin panel

```bash
cd web
npm install
npm run build          # writes backend/web/dist/
cd ../backend
go build ./...         # embeds dist/ into the binary
```

The shared-location group is called a **family** everywhere. Earlier builds
used “group” and “circle” for the same idea; those are gone.

## Roadmap

Shipped: auth, families, devices, live map, places, geofences, ntfy / APNs,
SOS / Help / Check in, emergency contacts, history, avatars, biometric
unlock, 90-day retention, audit log, invite-gated registration, and the
web admin panel.

Not in this release (ideas, not promises):

- Adaptive, battery-aware tracking driven by activity recognition
- Driving reports / trip summaries
- Passkeys (WebAuthn)
- End-to-end encryption of location (conflicts with server-side geofences)
- Crash detection

iOS background tracking is limited by Apple; Android OEM battery managers
can still kill the service despite a correct foreground service. Those are
platform constraints, not bugs we can fully paper over.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

Report security issues privately — see [SECURITY.md](SECURITY.md).

## License

OpenFamily is licensed under the [GNU Affero General Public License
v3.0](LICENSE).

## Acknowledgments

- [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors for
  the map data (© ODbL)
- [flutter_map](https://docs.fleaflet.dev/) and [Leaflet](https://leafletjs.com/)
  for rendering it
- [ntfy](https://ntfy.sh/) and [UnifiedPush](https://unifiedpush.org/) for
  Google-free Android notifications
- [TimescaleDB](https://www.timescale.com/) and [PostGIS](https://postgis.net/)
  for history and geofences
- [tileserver-gl](https://github.com/maptiler/tileserver-gl) for private maps
- [background_locator_2](https://pub.dev/packages/background_locator_2) for
  the background location isolate we vendor and patch
