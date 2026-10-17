# Google Play listing artwork

`upload/` contains the listing-ready icon (512 × 512), feature graphic
(1024 × 500), and five phone screenshots (1080 × 1920).

The screenshots use actual production Flutter widgets with fictional data.
No real accounts, server credentials, family names, or locations were used.
The server screen and feature graphic explicitly disclose server setup.

Regenerate on macOS:

```sh
cd app
flutter test tool/store_assets_capture_test.dart
cd ..
python3 assets/google-play/build_assets.py
```

The capture script loads Arial from macOS to avoid Flutter test placeholder
glyphs and uses the SDK's Material Icons font. Pillow is needed to package
the raw captures. No production app behavior is changed by this tooling.

Upload screenshot order: server, live map, people, places, invite.

Use `feature-map-1024x500.png` for the feature graphic. The map is the
production MapScreen with fictional family members around Central Park.
Map imagery © OpenStreetMap contributors, https://www.openstreetmap.org/copyright.
`fetch_map_tiles.py` fetches only the small area used in this capture and
caches the tiles locally for repeatable rendering.
