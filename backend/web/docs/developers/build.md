# Build and test

Everything can run in Docker; nothing needs installing on the host.

| Part | Command |
| --- | --- |
| Whole stack | `docker compose up -d --build` |
| Go tests | `docker run --rm --network host -v openfamily-go-cache:/go -v "$PWD":/r -w /r/backend golang:1.27 go test -p 1 -count=1 ./...` (needs a Timescale test database, see `TEST_DATABASE_URL` in `.github/workflows/test.yml`) |
| Flutter tests | `cd app && flutter test` (or the `ghcr.io/cirruslabs/flutter:stable` image) |
| Admin web | `cd web && npm ci && npm test && npm run build` (writes `backend/web/dist`, commit it) |
| Docs | `scripts/docs-check.sh` (links, images, embedded copy); `scripts/docs-check.sh --fix` refreshes `backend/web/docs` |
| Screenshots | `scripts/docs-screenshots.sh`, see [Screenshots](screenshots.md) |
| Licences | `scripts/license-check.sh` (every dependency must be in [THIRD_PARTY_LICENSES](../THIRD_PARTY_LICENSES.md)) |

Android releases: [android-release.md](../android-release.md),
[google-play-release.md](../google-play-release.md); iOS: [IOS_RELEASE.md](../design/IOS_RELEASE.md).
Testing guides: [E2E lanes](../testing/E2E_LANES.md), [physical devices](../testing/PHYSICAL_DEVICES.md).

## Editing the docs

Write Markdown under `docs/`. Use relative links and give every image alt text.
Add a page to `docs/nav.json` to place it in a category (unlisted pages appear
under "More"). Run `scripts/docs-check.sh --fix` and commit `backend/web/docs`.

## Brand assets and the rename script

The logo, icons and social images are generated from `assets/brand/generate.py`
(SVG sources, Android vector drawables) and `assets/brand/build-rasters.mjs`
(every PNG and the ICO, using headless Chromium; no fonts or other tools). Run
`python3 assets/brand/generate.py && node assets/brand/build-rasters.mjs` after
changing the mark. The palette and geometry are at the top of `generate.py`.

`scripts/rebrand.sh` renames user-visible product-name strings and is safe to
run again after merging other work; `scripts/rebrand.sh --verify` runs in CI.
Which internal names stay `openfamily` is in [Naming](naming.md).
