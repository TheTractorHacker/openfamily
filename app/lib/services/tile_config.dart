import 'api_client.dart';
import 'secure_url.dart';
import 'server_features.dart';

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

  /// Pulls `tile_url` / `satellite_tile_url` from the configured server.
  /// Missing or empty fields keep the current values.
  Future<void> refresh() async {
    try {
      final Map<String, dynamic> cfg = await ApiClient.getPushConfig();
      final String? street = cfg['tile_url'] as String?;
      final String? satellite = cfg['satellite_tile_url'] as String?;
      if (street != null && isHttpsUrl(street)) {
        streetUrl = street.trim();
      }
      if (satellite != null && isHttpsUrl(satellite)) {
        satelliteUrl = satellite.trim();
      }
      ServerFeatures.instance.apply(cfg);
    } catch (_) {
      // Keep whatever we already have (defaults or a previous successful fetch).
    }
  }

  void resetToDefaults() {
    streetUrl = kDefaultStreetTileUrl;
    satelliteUrl = kDefaultSatelliteTileUrl;
  }
}
