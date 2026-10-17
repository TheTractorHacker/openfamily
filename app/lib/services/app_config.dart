// Build-time configuration for the OpenFamily app.
//
// The API URL may be hinted via `--dart-define=OPENFAMILY_API_URL` but the
// stored preference always wins. ServerConfig accepts only HTTPS URLs. Map
// tiles come from GET /config at runtime and are also required to use HTTPS.

import 'tile_config.dart';

export 'tile_config.dart'
    show kDefaultStreetTileUrl, kDefaultSatelliteTileUrl;

/// Optional compile-time HTTPS hint for the API URL. Used only when the user
/// has never saved a server address. Release APKs leave this empty.
const String kApiBaseUrl = String.fromEnvironment('OPENFAMILY_API_URL');

/// Street tiles currently in use (defaults, then operator `/config`).
String get kTileUrl => TileConfig.instance.streetUrl;

/// Satellite tiles currently in use (defaults, then operator `/config`).
String get kSatelliteTileUrl => TileConfig.instance.satelliteUrl;
