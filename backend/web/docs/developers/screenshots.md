# How the screenshots are made

All images under `docs/images/` are generated, not hand-edited, and show only
made-up data (the "Rivera Family", `example.com` addresses).

- **Admin web** (`docs/images/web/`): `scripts/docs-screenshots.sh` starts a
  throwaway copy of the stack from this checkout (own Docker project name and
  ports, never your real stack), seeds it with demo data, and uses Playwright
  (Chromium in Docker) to capture desktop and phone widths, light and dark.
- **Phone app** (`docs/images/app/`): rendered by a Flutter widget test
  (`app/test/goldens/docs_screenshots_test.dart`) with fake data and fake
  services. **These are drawn from the widget tree on a computer with the
  Roboto font, not captured from a real phone.** Real devices differ slightly
  (system font, status bar, map tiles, which are left out).
- Images are quantised/optimised to keep the repository and the server image
  small (about 8 MB in total).

Regenerate everything: `scripts/docs-screenshots.sh` (needs Docker). Then run
`scripts/docs-check.sh --fix` to refresh the copy embedded in the server.
