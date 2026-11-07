# Share links ("share your live location with anyone")

A person can mint a link that anyone can open in a browser, with no app and no
account, to follow their live location until it expires or is stopped.

## Endpoints

Authenticated:

- `POST /share-links` `{minutes (1..4320), label?}` returns `{id, url, token,
  created_at, expires_at, label}`. The token (256 random bits, base64url) and
  `url` (`PublicBaseURL` or the request host, plus `/s/<token>`) appear only in
  this response. At most 10 active links per user (409), 30 creations per hour.
- `GET /share-links` lists the caller's active links (no token).
- `DELETE /share-links/{id}` stops sharing at once (uniform 404 for anything
  that is not the caller's active link).

Public, unauthenticated:

- `GET /s/{token}` the self-contained viewer page.
- `GET /s/{token}/data` JSON the page polls every 5 s while visible:
  `state` (`active` | `paused` | `no_location`), `name`, `initial`,
  `photo_url?`, `lat`, `lon`, `accuracy_m`, `heading_deg`, `speed_mps`,
  `battery_pct`, `updated_at`, `expires_at`. Nothing else: no id, email,
  circle, or history. While the owner's sharing is paused, `state` is `paused`
  and no location or battery is returned.
- `GET /s/{token}/photo` the owner's avatar while the link is live.

## Storage and hardening

- Table `share_links` (migration 000112) stores `SHA-256(token)` only.
- Unknown, malformed, expired and revoked tokens give the same generic 404
  (identical body), so a response never reveals which. Expiry and revocation
  are evaluated in SQL on every request; the viewer stops immediately.
- Lookup is by hash (index key) and the stored hash is re-compared in constant
  time.
- Per-IP rate limits: 150 requests/min, and 30 misses per 15 min (429).
- Headers: `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
  `X-Robots-Tag: noindex`, nosniff, frame denial, and a CSP of
  `default-src 'none'` with a nonce for the one inline script, `connect-src
  'self'`, and `img-src 'self' data:` plus the operator's tile host.

## Map tiles and privacy

The page loads no CDN script or font. Its map is a small slippy-map written in
the page itself, drawing raster tiles from the same `TILE_URL` that `/config`
advertises (must be https; default OpenStreetMap). The viewer's browser
therefore contacts that tile host, which sees the viewer's IP and the area
viewed. Tile images are requested with `referrerpolicy=origin`, so the tile host
gets this server's origin but never the secret path. To keep tile traffic on
your own infrastructure, point `TILE_URL` at a self-hosted tile server (see
[maps.md](maps.md)). Vector styles (`MAP_STYLE_URL`) are not used by the page.
