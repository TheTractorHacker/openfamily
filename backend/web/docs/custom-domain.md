# Custom domains

Serving OpenFamily behind a real domain name (for example
`openfamily.example.com`) gives every device automatic HTTPS: Caddy requests
and renews a Let's Encrypt certificate for you. No certbot, no manual renewal.

The admin panel (**Settings → Custom domain**) shows your current setup and
runs live DNS and HTTPS checks against it, so you can verify each step below
without SSH-ing into the server.

## 1. Point DNS at the server

At your DNS provider, create a record for the name you want:

| Record | Name                  | Value                  |
|--------|-----------------------|------------------------|
| A      | `openfamily.example.com` | your server's public IPv4 |
| AAAA   | `openfamily.example.com` | your server's public IPv6 (optional) |

If your server sits behind a router (home NAS), forward external ports **80**
and **443** to it. Port 80 is required even though traffic ends up on 443:
Let's Encrypt uses it for the initial challenge and for HTTP→HTTPS redirects.

DNS changes can take minutes to hours to propagate. The panel's **DNS** check
tells you when the name resolves.

## 2. Set the domain in `.env`

In the `.env` file next to `docker-compose.yml`:

```bash
SITE_ADDRESS=openfamily.example.com
ALLOWED_ORIGIN=https://openfamily.example.com
PUBLIC_BASE_URL=https://openfamily.example.com
APP_ENV=production
```

- `SITE_ADDRESS` — what Caddy serves; this is what triggers certificate
  issuance.
- `ALLOWED_ORIGIN` — must match the origin exactly (scheme included) or app
  clients will fail CORS.
- `PUBLIC_BASE_URL` — used for share links in SMS alerts.

## 3. Apply and verify

```bash
docker compose up -d
```

Caddy obtains the certificate on startup (it may take a few seconds). The
panel's **HTTPS** check passes once `https://your-domain/healthz` answers from
the server with a valid certificate.

Then point the apps at `https://your-domain` (Settings → About → Copy server
URL in the web panel).

> **Home-network note:** some routers do not support NAT loopback, so the
> server may not be able to reach its own domain even though phones outside
> the network can. If the HTTPS check fails but everything else works, test
> from a phone on mobile data before debugging further.

## Android push on its own subdomain

Phones on the public internet need to reach the ntfy push server over TLS.
Give it a second name (e.g. `push.example.com`, an A record at the same IP)
and set in `.env`:

```bash
PUSH_ADDRESS=push.example.com
NTFY_BASE_URL=https://push.example.com
CADDYFILE=Caddyfile.with-push
```

Keep ntfy bound to loopback only (the Compose default); Caddy is the only
public entrypoint. See [self-hosting.md](self-hosting.md) for details.

## Troubleshooting

- **"DNS check fails: does not resolve yet"** — the record does not exist or
  has not propagated. Double-check the name and value at your provider.
- **Certificate errors right after switching** — Caddy needs outbound access
  to Let's Encrypt and inbound port 80 for the challenge. Wait a minute and
  re-run the checks.
- **App can't connect after the switch** — `ALLOWED_ORIGIN` usually doesn't
  match `https://your-domain` exactly.
- **Domain changed?** Update `SITE_ADDRESS`, `ALLOWED_ORIGIN`,
  `PUBLIC_BASE_URL` (and the push trio if used) together, then
  `docker compose up -d`. All values live in `.env`, which survives server
  self-updates.
