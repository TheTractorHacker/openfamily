# Privacy

OpenFamily is a self-hosted family location tracker. This document describes
what the software stores and who can see it. The operator of each deployment
is the data controller for that instance. The app requires an HTTPS server URL
and refuses cleartext HTTP connections.

## What is stored

- **Accounts:** email, display name, optional phone number, password hash
  (Argon2id), optional avatar bytes.
- **Family membership and roles:** admin, member, or child.
- **Devices:** platform, name, push endpoint, last seen.
- **Live and historical location:** coordinates, time, accuracy, battery,
  motion. History is kept for **90 days** (TimescaleDB retention). The last
  known point per person (`member_positions`) is kept until the account is
  deleted so inactive members still appear on the map.
- **Places and geofences:** names, points, radii, arrive/leave flags.
- **Safety alerts:** SOS / Help / Check-in notes and short-lived share tokens
  (24 hours).
- **Emergency contacts:** name and phone (for optional SMS).
- **Audit log:** auth and admin actions. Location ingest logs a device id, not
  raw coordinates (once that backend change is deployed).

There is **no analytics SDK**, crash reporter, or vendor location pipeline in
the app.

## About this website

The project website pages in `site/` are static and separate from the software.
They set no cookies and ship no analytics or tracking code.

## Who can see location

- Members of the same family (including the child role, who can view the map
  but cannot edit places).
- The platform admin of that server (`/admin`), if one is configured.
- Emergency contacts, only when SOS fires and optional Twilio SMS is enabled.
  The SMS carries a 24-hour share URL on *your* server when `PUBLIC_BASE_URL`
  is HTTPS; otherwise it may fall back to lat/lon.

## What leaves your server

- **Map tiles:** by default the phone loads public OpenStreetMap (street) and
  Esri (satellite) images. Those hosts see the map viewport (roughly where you
  are looking). Set `TILE_URL` / `SATELLITE_TILE_URL` on the server to use
  another provider or your own tiles; the app ignores tile URLs that do not use
  HTTPS. A key in that URL is visible to every
  phone and to anyone who can call `GET /config`.
- **Android push:** your ntfy server (or another UnifiedPush distributor).
  Payloads omit the tracked person's name unless `VERBOSE_PUSH=true`.
- **iOS push:** APNs (platform requirement). Payloads do not include
  coordinates.
- **Optional SMS:** Twilio sees destination numbers and the share URL.

## Your controls

- **Location sharing** toggle: this device stops reporting.
- **Change or delete account** in the Android app (delete is blocked if you
  are the last admin of a family that still has other people).
- **Biometric unlock** covers the UI; it does not encrypt background
  credentials used to report location.

## Operator duties

Encrypt the disk (or Postgres) at rest, keep backups private, set
`APP_ENV=production`, and close open registration with `PLATFORM_ADMIN_EMAIL`.
See [docs/self-hosting.md](docs/self-hosting.md).

## Contact and deletion

For a request about account data on a deployment, contact that server's
operator; the software publisher cannot access or delete data on an
independently operated server. Users can delete an account in the app or
follow the public [account deletion instructions](https://foleyit.com/delete-account.html).
For OpenFamily software support or help finding the right deletion steps,
contact `info@foleyit.com`. The public [privacy policy](https://foleyit.com/privacy.html)
describes data handling and external services.
