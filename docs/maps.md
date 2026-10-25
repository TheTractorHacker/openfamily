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

## Not verified in code review

Visual quality and rendering performance of vector mode on real devices have
not been checked; adjust `layerMode` / `concurrency` in the shared layer if
older phones struggle.
