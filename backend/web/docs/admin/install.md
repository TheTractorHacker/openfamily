# Install the server with Docker Compose

This guide takes you from an empty machine to a running OpenFamily server. You
need about 20 minutes and a computer that stays on: a small home server, a
NAS that runs Docker, a Raspberry Pi 4 or newer, or a rented VPS.

## What you need

- A Linux machine (or NAS) with **Docker** and **Docker Compose v2**
  (`docker compose version` prints a version).
- 1 GB of free RAM and a few GB of disk. Locations are small.
- Optional but recommended: a domain name (see [HTTPS and your own domain](https-and-domain.md)).

## Step by step

1. **Get the code.**

   ```bash
   git clone https://github.com/TheTractorHacker/openfamily.git
   cd openfamily
   ```

2. **Create your settings.** The setup script writes a `.env` file with
   random passwords and asks two questions: your address and the admin email.

   ```bash
   ./scripts/setup.sh
   ```

   Answer `:80` for a first test on your own network, or your domain name
   (for example `family.example.com`) for the internet. It never overwrites an
   existing `.env`. The admin password is shown once; save it in a password
   manager.

3. **Start the server.**

   ```bash
   docker compose up -d --build
   ```

   The first build takes a few minutes. The documentation you are reading is
   built into the server image, so it is available offline afterwards.

4. **Check that it is alive.**

   ```bash
   curl http://localhost:8080/healthz
   # {"status":"ok"}
   ```

5. **Open the admin web** at `http://localhost:8080/admin/` (or your domain
   plus `/admin/`) and sign in with the admin email and password from step 2.
   Continue with [First run](first-run.md).

## Where things live

| What | Where |
| --- | --- |
| Settings | `.env` next to `docker-compose.yml` |
| Family data | Docker volume `pgdata` (Postgres) |
| Backups | `./backups/` after you run `scripts/backup.sh` |
| Logs | `docker compose logs -f api` |

## Stop, start, remove

```bash
docker compose stop        # stop, keep data
docker compose up -d       # start again
docker compose down        # remove containers, KEEP data
docker compose down -v     # DANGER: also deletes the database
```

Next: [First run](first-run.md), [Backups](backups.md), [Updates](updates.md).
The full checklist for internet-facing servers is in [Self-hosting](../self-hosting.md).
