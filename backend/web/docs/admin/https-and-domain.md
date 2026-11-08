# HTTPS, reverse proxies and your own domain

Phones should always talk to your server over HTTPS. There are two ways to get it.

## Option A: the built-in Caddy (easiest)

1. Point a DNS name at your server and forward ports 80 and 443
   ([custom domain guide](../custom-domain.md) has the DNS table).
2. In `.env` set `SITE_ADDRESS=family.example.com` and `COMPOSE_PROFILES=proxy`.
3. `docker compose up -d`. Caddy gets and renews a Let's Encrypt certificate.
4. In the admin web open **Settings, Custom domain**: it checks DNS and HTTPS for you.

## Option B: your own reverse proxy

Already running nginx, Traefik or Nginx Proxy Manager? Leave `proxy` off and
point it at `127.0.0.1:8080`. Keep `TLS_BEHIND_PROXY=true`. Pass WebSocket
upgrades (`/ws/stream`, `/api/admin/ws`) and do not buffer `/push/stream`
(server-sent events).

## Home network without a domain

Use the server's LAN address (`http://192.168.1.20:8080`) while at home. Phones
leaving home will not reach it: use a domain, or a VPN such as WireGuard or
Tailscale. Plain `http` on the internet is not supported.

Details and troubleshooting: [Custom domains](../custom-domain.md) and
[Self-hosting](../self-hosting.md#before-docker-compose-up).
