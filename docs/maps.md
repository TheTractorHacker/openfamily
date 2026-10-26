# Maps

The Android/iOS app draws its base map with **vector tiles** (crisp at any
density) from [OpenFreeMap](https://openfreemap.org): free, no API key, no
account. Light and dark map styles follow the app theme (`positron` /
`dark`). Satellite stays a raster layer.

All map widgets use one shared layer, `app/lib/widgets/openfamily_map_layers.dart`,
configured by `app/lib/services/map_style_service.dart`.

## Resolution order

1. Satellite toggle: raster `SATELLITE_TILE_URL` (default Esri World Imagery).
2. `TILE_URL` set to anything other than the stock OSM URL: raster tiles from
   that template (use `{r}` in the template for `@2x` tiles; the app then
   requests high-DPI tiles on dense screens).
3. `MAP_STYLE_URL` set: vector style JSON from that URL (MapLibre style with
   an OpenMapTiles-schema source).
4. Default: OpenFreeMap `positron` (light) or `dark` (dark theme).

If the vector style cannot be loaded (offline, server error) the app falls
back to the raster `TILE_URL` (OSM by default) and retries the style after 30
seconds. The fallback hits OSM, so avoid relying on it for heavy use.

Settings are served by `GET /config` (`tile_url`, `satellite_tile_url`,
`map_style_url`) and set through `.env` / `docker-compose.yml`. All must be
HTTPS. `/config` is public, so a key embedded in a URL is visible to every
phone.

## Tile policy and identification

The app sends `User-Agent: app.openfamily ...` to style and tile hosts, and
`userAgentPackageName='app.openfamily'` on raster layers. The public OSM
servers block clients that do not follow their tile usage policy and are not
meant for production apps; run your own tiles or use a provider that permits
app use if you ship to many users.

## Caching and data use

Vector tiles are cached on disk (temporary directory) with a bounded size:
50 MB by default, 25 MB in reduced-data mode, 14 day TTL, plus small
in-memory caches. Raster fallback tiles use flutter_map's default cache.
The style JSON itself is held in memory only, so a cold start offline falls
back to raster.

## Privacy

Every tile request tells the tile host the phone's IP address, the area being
viewed (tile coordinates), and the app User-Agent. With the defaults that
host is `tiles.openfreemap.org` (and `tile.openstreetmap.org` for fallback,
Esri for satellite). To keep that inside your own infrastructure, self-host
tiles and point the app at them.

## Self-hosting

- **OpenFreeMap**: it publishes a self-hosting guide and scripts for serving
  the planet from static files behind nginx (see openfreemap.org, "Self
  hosting"). Then host a style JSON whose `sources.openmaptiles.url` points
  to your TileJSON and set `MAP_STYLE_URL=https://maps.example.com/style.json`.
  The style also needs `glyphs` and `sprite` URLs you host.
- **Protomaps PMTiles**: serve a regional `.pmtiles` file with a PMTiles
  server (or the go-pmtiles binary) that exposes `{z}/{x}/{y}.mvt`, and
  publish a MapLibre style (Protomaps basemaps flavors differ from the
  OpenMapTiles schema, so check layer compatibility) with sprites and glyphs.
  The app's renderer expects OpenMapTiles-style layers.
- **Raster only**: any `{z}/{x}/{y}.png` server (including a self-hosted
  tileserver) works via `TILE_URL`; this disables the vector path.

Example `.env`:

```
MAP_STYLE_URL=https://maps.example.com/styles/liberty.json
# or raster only:
TILE_URL=https://tiles.example.com/{z}/{x}/{y}{r}.png
```

## Address search and automatic address detection

Creating or editing a place offers (a) an address filled in automatically when
you drop or move the pin (reverse geocoding) and (b) autocomplete suggestions
while you type an address. The app calls only your OpenFamily server
(`GET /geocode/search`, `GET /geocode/reverse`, signed-in users only,
rate-limited per user); the server queries one geocoder provider.

**Default: on, using the public Photon at `https://photon.komoot.io`.** That
means the address text people type and the coordinates of places they pin are
sent from your server to photon.komoot.io, which also sees your server's IP.
The phone never contacts it. The server sends only a descriptive User-Agent
(`OpenFamily/<version> (self-hosted)`), forwards no user identity, tokens or
client IP, caches results in memory per signed-in user (never shared, so no one can learn by response time whether someone else looked up the same address; upstream requests are never merged across users), and never logs query text or
coordinates (only counts, status and latency). Lookups happen only while a
user is editing a place, not for live location tracking.

Settings (server environment):

| Variable | Meaning |
| --- | --- |
| `GEOCODER_URL` | Provider base URL. Unset = public Photon. **Set to empty to disable** (the app then hides search and the server answers 503). |
| `GEOCODER_TYPE` | `photon` (default) or `nominatim`. |
| `GEOCODER_LANG` | Optional result language, e.g. `en`. |
| `GEOCODER_ALLOW_PRIVATE` | `true` to allow a loopback/private-network provider (self-hosted next to the API). Otherwise private and loopback targets are refused (SSRF guard), `http` is refused, redirects are never followed. |

`GET /config` reports only `geocoder: {"enabled", "autocomplete"}`, never the URL.

Self-hosting: run Photon (github.com/komoot/photon; it needs an OpenSearch
index built from a Nominatim dump or the published country extracts) or
Nominatim (nominatim.org) on your network and set, for example,
`GEOCODER_URL=http://photon:2322` plus `GEOCODER_ALLOW_PRIVATE=true`. The
public `nominatim.openstreetmap.org` prohibits autocomplete: if you point a
`nominatim` type at it, autocomplete is disabled, only explicit searches are
allowed, limited to one request per second, and a startup warning is logged.
Public Photon is a shared fair-use service with no uptime guarantee.

## Not verified in code review

Visual quality and rendering performance of vector mode on real devices have
not been checked; adjust `layerMode` / `concurrency` in the shared layer if
older phones struggle.
