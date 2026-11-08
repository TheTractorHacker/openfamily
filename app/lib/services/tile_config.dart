import 'accent_preference.dart';
import 'api_client.dart';
import 'offline/offline_cache.dart';
import 'secure_url.dart';
import 'server_features.dart';
import 'speed_units.dart';

/// Public OSM street tiles. Used until [GET /config] supplies an override.
const String kDefaultStreetTileUrl =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Esri World Imagery. Used until [GET /config] supplies an override.
const String kDefaultSatelliteTileUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// Runtime raster tile templates from the operator's `GET /config`.
///
/// Defaults match today's OSM / Esri hosts so a first launch still paints a
/// map when the server omits the new fields (or the backend PR is not live).
class TileConfig {
  TileConfig._();

  static final TileConfig instance = TileConfig._();

  String streetUrl = kDefaultStreetTileUrl;
  String satelliteUrl = kDefaultSatelliteTileUrl;

  /// Operator MAP_STYLE_URL (vector style JSON). Empty = built-in OpenFreeMap.
  String mapStyleUrl = '';

  /// Pulls `tile_url` / `satellite_tile_url` from the configured server.
  /// Missing or empty fields keep the current values.
  Future<void> refresh() async {
    try {
      // The last answer is kept, so an offline start still knows the map style and which
      // features (SMS, processing) this server offers.
      final Map<String, dynamic> cfg = (await OfflineCache.instance.fetch<Map<String, dynamic>>(
        'server-config',
        () => ApiClient.getPushConfig(),
        encode: (Map<String, dynamic> v) => v,
        decode: (Object? j) => Map<String, dynamic>.from(j! as Map),
      ))
          .value;
      final String? street = cfg['tile_url'] as String?;
      final String? satellite = cfg['satellite_tile_url'] as String?;
      if (street != null && isHttpsUrl(street)) {
        streetUrl = street.trim();
      }
      if (satellite != null && isHttpsUrl(satellite)) {
        satelliteUrl = satellite.trim();
      }
      final String? style = cfg['map_style_url'] as String?;
      if (style != null && style.trim().isNotEmpty && isHttpsUrl(style)) {
        mapStyleUrl = style.trim();
      } else if (style != null) {
        mapStyleUrl = '';
      }
      ServerFeatures.instance.apply(cfg);
      AccentPreferenceService.applyServer(cfg);
      UnitPreferenceService.applyInstanceDefault(
          parseUnitSystem(cfg['default_units']));
    } catch (_) {
      // Keep whatever we already have (defaults or a previous successful fetch).
    }
  }

  void resetToDefaults() {
    streetUrl = kDefaultStreetTileUrl;
    satelliteUrl = kDefaultSatelliteTileUrl;
    mapStyleUrl = '';
  }
}
