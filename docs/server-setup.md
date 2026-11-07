# Server setup: adding your own server to a circle

This page is for the person who runs the OpenFamily server for their family. It takes about ten minutes.
Phones keep working without the server. Adding the server is what lets it keep **history, driving reports,
trips and the map** for the people who say yes.

## 1. Tell the server where it runs

Open the admin panel, **Settings > Server setup**, and choose:

* **At home**: a NAS, mini PC or Raspberry Pi that you own and that sits in your house. The app then offers
  "Add server" first, because only you can touch the disk.
* **Rented**: a VPS or hosted server. The company running the machine could read what the server can read. The
  app keeps location on the phones unless somebody deliberately adds the server.

If you do not choose, the server behaves as **rented** (the careful side). In `.env` the same choice is
`DEPLOYMENT_PROFILE=home` or `cloud` (`./scripts/setup.sh` asks). The setting in the admin panel wins once made.
The choice changes advice and defaults only. Nobody is added to anything by it.

### Rented server: protect the disk

* Turn on **full-disk or volume encryption** (LUKS, or your provider's encrypted volume). OpenFamily cannot see
  your disk, so it cannot check this for you.
* Set `OPENFAMILY_DATA_KEY` (`./scripts/setup.sh` does this for a rented server). It encrypts stored secrets
  (SMS token, webhook secrets) in the database. **Keep a copy outside the server**, for example in a password
  manager. Once it has been used the server will not start without it, so that secrets are never written
  unprotected by accident. Losing it loses only those secrets, not your locations.
* Change the key later: generate a new one, keep it safe, then
  `docker compose exec api server data-key generate` (prints a new key) and
  `docker compose exec api server data-key rewrap NEW_KEY`, put NEW_KEY in `.env`, restart.
* Turn on encrypted backups (`docs/backup-restore.md`).

**What stays readable in the database while the server runs:** locations, speed, heading, trips, driving
reports, history, place names. The server must read them to draw the map and notice arrivals. A stolen disk
image of a running or unencrypted machine therefore shows them. Disk encryption and a trusted host are the
protection for that part, not the data key.

## 2. Give the server its key (once)

The server keeps its own key in a separate container (`e2ee-server-device`), never next to the database
password. In the admin panel the Server setup card shows the exact lines to copy. In short, in the folder with
`docker-compose.yml`:

```bash
echo "E2EE_SERVER_INGEST_TOKEN=$(openssl rand -hex 32)" >> .env
echo "COMPOSE_PROFILES=${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}e2ee-server" >> .env   # edit if you already use profiles
docker compose up -d
read -rsp 'Your OpenFamily password: ' P; echo
printf '%s\n' "$P" | docker compose --profile e2ee-server run --rm -T e2ee-server-device \
    enroll --kind server --server http://api:8080 --email you@example.org
```

It prints a **request code**. On your phone open **Settings > Encryption keys > Approve a viewer or bridge**,
paste it and copy the **approval code** the phone shows, then:

```bash
docker compose --profile e2ee-server run --rm e2ee-server-device enroll --approval PASTE_THE_CODE
docker compose --profile e2ee-server up -d e2ee-server-device
```

Use the login of the person who is circle admin. The key is stored in the `e2ee_server_state` volume.

## 3. Compare the key, then tap OK

In the app open the circle and tap **Add server to this circle**. It shows four groups of characters. The admin
panel (Settings > Server setup, step 4) shows the same four groups and a QR code. If they are **the same**, tap
OK. If they differ, stop: do not continue and check that you are on your own server's address.

* The circle admin's OK turns server help on for the circle. Each other member still has to say yes on their
  own phone, and can say no, or remove the server later (their copies on the server are then deleted).
* "Remove server" in the same sheet takes the server away again.
* If the app says the server is not set up yet, step 2 is not finished.

## 4. Install the apps and invite family

Android: open `https://YOUR-SERVER/app.apk` on the phone. In the app create a circle, tap Invite and share the
code. Everyone enters it when they join.
