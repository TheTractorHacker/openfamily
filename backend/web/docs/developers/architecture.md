# Architecture

```
 phone (Flutter app)  --HTTPS/WebSocket-->  Caddy (optional)  -->  api (Go, one binary)  --> Postgres + TimescaleDB
 browser (admin web)  ------------------------------------------>  embedded SPA + /api/admin/*
```

- **backend/**: the Go API (chi router, pgx, golang-migrate). One static binary
  that also serves the admin web (`backend/web/dist`, embedded) and the
  documentation (`backend/web/docs`, embedded). Migrations in
  `backend/internal/db/migrations/` run at startup.
- **app/**: the Flutter app for Android and iOS, with a vendored fork of
  `background_locator_2` and a native `driving_native` plugin.
- **web/**: the admin web source (Vite, React, Leaflet and MapLibre). Its
  production build is committed to `backend/web/dist`.
- **docs/**: this documentation. `scripts/docs-bundle.mjs` copies it into
  `backend/web/docs` so the server ships its own manual.
- **scripts/**: operations (`setup.sh`, `backup.sh`, `upgrade.sh`) and
  quality gates (`license-check.sh`, `docs-check.sh`).

## Privacy architecture

Circles are **Normal** (server reads positions) or **Private** (end-to-end
encrypted between phones; the server holds ciphertext). Within a Private circle
each person can opt in to server help. Read, in this order:
[Privacy processing ADR](../design/PRIVACY_PROCESSING.md), [E2EE ADR](../design/E2EE.md),
[Processing on device](../design/PROCESSING_ON_DEVICE.md), [Circles](../design/CIRCLES.md).

## More

- [Baseline audit (historic)](../architecture/CURRENT_STATE.md)
- [Live tracking](../live-tracking.md), [live tracking client](../live-tracking-client.md), [live map](../live-tracking-map.md)
- [Reliability](../reliability.md), [Performance](../performance.md), [Maps](../maps.md)
- [Design system](../ux/DESIGN_SYSTEM.md)
