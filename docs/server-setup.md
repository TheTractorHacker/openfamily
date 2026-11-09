# Server setup: adding your own server to a circle

This page is for the person who runs the Orbitly server for their family. It takes about five minutes.
The short version: **the server joins itself, you tap approve once, and everyone is on the server by default
and can opt out.**

* Circles are **Private** (end-to-end encrypted between the phones) and your server takes part as its own
  device, so it keeps **history, driving reports, trips and the map** for everyone.
* Each person's own phone switches server processing on for them, with a notice. Anyone who prefers taps
  **Keep on my phone** (or later Settings > Server processing). Nobody can switch another person on.
* The steps: pick where the server runs, approve the server on your phone, install the apps and create your
  circle. What members see and how they opt out: [Server processing](user/server-processing.md).

## 1. Tell the server where it runs

Open the admin panel, **Settings > Server setup**, and choose:

* **At home**: a NAS, mini PC or Raspberry Pi that you own and that sits in your house. Only you can touch the disk.
* **Rented**: a VPS or hosted server. The company running the machine could read what the server can read. The
  app says so whenever someone adds the server, and the steps below (disk and data-key protection) matter more.

New circles use the server by default in both cases (the circle creator can pick "Private, phones only" or
"Normal" instead, and each member can opt out). If you do not choose, the server uses the **rented** wording
(the careful side). In `.env` the same choice is
`DEPLOYMENT_PROFILE=home` or `cloud` (`./scripts/setup.sh` asks). The setting in the admin panel wins once made.
The choice changes advice and defaults only. Nobody is added to anything by it.

### Rented server: protect the disk

* Turn on **full-disk or volume encryption** (LUKS, or your provider's encrypted volume). Orbitly cannot see
  your disk, so it cannot check this for you.
* Set `OPENFAMILY_DATA_KEY` (`./scripts/setup.sh` does this for a rented server). It encrypts stored secrets
  (SMS token, webhook secrets) in the database. **Keep a copy outside the server**, for example in a password
  manager. Once it has been used the server will not start without it, so that secrets are never written
  unprotected by accident. Losing it loses only those secrets, not your locations.
* Change the key later: generate a new one, keep it safe, then
  `docker compose exec api server data-key generate` (prints a new key) and
  `printf '%s\n' "$NEW_KEY" | docker compose exec -T api server data-key rewrap --stdin`, put NEW_KEY in `.env`, restart.
* Turn on encrypted backups (`docs/backup-restore.md`).

**What stays readable in the database while the server runs:** locations, speed, heading, trips, driving
reports, history, place names. The server must read them to draw the map and notice arrivals. A stolen disk
image of a running or unencrypted machine therefore shows them. Disk encryption and a trusted host are the
protection for that part, not the data key.

## 2. Approve on your phone

You do not run any command. The server creates its own key the first time it starts and keeps it in the
`server_device` Docker volume (`/data/server-device`, files readable only by the server). The admin panel
(Settings > Server setup) shows a short code of four groups. Your phone gets a message **"Your server wants
to join"**; if you do not get it, the same prompt shows at the top of the app when you open it. Check that the
code is **the same**, then tap **Yes, it matches - approve**. If it differs, stop and check that you are on your
own server's address.

* Only a server administrator can approve. Approving signs nothing for anyone: it lets the server's key take
  part. If you have not approved it yet when you create your first circle, the app opens this same step right
  there, so you approve and create in one go.
* The card finishes by itself and turns into a green **Server is processing**.
* **Where the key lives (accepted trade-off):** the server's private key is now on the server's own disk
  volume, next to the database. Someone who can read the whole machine can read what the server can read
  anyway. On a rented server set `OPENFAMILY_DATA_KEY`: it then also encrypts the key file at rest, so a copied
  volume alone is not enough. The server key only ever receives the server key line, never a circle key.
* Back up the `server_device` volume together with the database. Losing it only means the server must be
  approved again.

### Details: the separate container (advanced)

Cloud and security-minded operators can keep the key in a separate container, away from the database. Set
`E2EE_SERVER_INGEST_TOKEN` (or `OPENFAMILY_SERVER_DEVICE=sidecar`) and follow the commands under
**Details** on the Server setup card, or [the sidecar README](https://github.com/TheTractorHacker/orbitly/blob/main/backend/cmd/e2ee-bridge/README.md). The
built-in device is then switched off (`OPENFAMILY_SERVER_DEVICE=auto` decides; `builtin`, `sidecar` and `off`
force it).

## 3. Create your circle: everyone is on the server by default

In the app, create a circle. **Private, with your server (recommended)** is already selected: one tap on
**Create** makes the circle Private, switches server processing on and makes the server the default for
everyone who joins. (Tick **Everyone must use the server** for a circle with children's phones, where nobody
should be able to keep their data from the server; each member then confirms it once on their own phone.)

When someone joins and opens the app, **their own phone** switches server processing on for them and shows a
notice. They have nothing to do. Each person decides for themselves and can switch back at any time:

* **Use the server** (the default): the server keeps your locations so maps, history and driving reports just work.
* **Keep on my phone**: your location is shared privately, encrypted from phone to phone. You get no reports
  unless you turn on phone reports (uses more battery). Their copies on the server are deleted if they ask.

Want people to be asked instead of switched on? In the admin panel, **Settings > Default for new members**,
untick **Apply automatically**. The guide for members: [Server processing](user/server-processing.md).

## 4. Install the apps and invite family

Android: open `https://YOUR-SERVER/app.apk` on the phone. In your circle tap Invite and share the code.
Everyone enters it when they join; before joining the app tells them the circle uses the server by default
and that they can opt out.
