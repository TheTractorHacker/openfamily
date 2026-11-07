#!/usr/bin/env bash
# Documentation gate (CI "docs" step and web tests):
#   - every relative link, image and #anchor in docs/**/*.md and README.md resolves
#   - images have alt text
#   - backend/web/docs (the copy embedded in the server) matches docs/
# Needs Node 22+ (or Docker: set USE_DOCKER=1).  --fix regenerates the embedded copy.
set -euo pipefail
cd "$(dirname "$0")/.."
run() {
  if command -v node >/dev/null 2>&1 && [ -z "${USE_DOCKER:-}" ]; then
    node "$@"
  else
    docker run --rm -v "$PWD:/r" -w /r node:22 node "$@"
  fi
}
if [ "${1:-}" = "--fix" ]; then run scripts/docs-bundle.mjs; fi
run scripts/docs-check.mjs
run scripts/docs-bundle.mjs --check
