import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'secure_url.dart';

/// Privacy-first geocoding against a self-hosted Nominatim instance.
///
/// TODO(backend): Replace this with the real OpenFamily backend geocoding
/// endpoint (e.g. `POST /geocode` and `POST /reverse-geocode`) so address
/// lookups never leave your own server. Until that endpoint exists, this talks
/// to a self-hosted Nominatim base URL configured via
/// `--dart-define=OPENFAMILY_NOMINATIM_URL=https://nominatim.your.server`.
///
/// PRIVACY: geocoding is DISABLED by default (empty base URL) so the app never
/// sends a family member's coordinates or address queries to the public OSM
/// Nominatim endpoint. A self-hosted deployment must explicitly configure
/// [baseUrl] to enable lookups.
///
/// Every method degrades gracefully: a disabled service, network errors,
/// non-200 responses, and malformed payloads all resolve to `null` so the UI
/// can fall back to a manual address or a "Pinned location" label.
class GeocodingService {
  GeocodingService._();

  /// Base URL of the self-hosted Nominatim instance. Empty (disabled) unless
  /// configured at build time with `OPENFAMILY_NOMINATIM_URL`.
  static const String baseUrl = String.fromEnvironment(
    'OPENFAMILY_NOMINATIM_URL',
  );

  /// Whether address search / reverse-geocode is available. False by default
  /// so the place picker can fall back to pin-drop without pretending search
  /// works.
  static bool get isEnabled => isHttpsUrl(baseUrl);

  static const String _userAgent =
      'openfamily/0.1 (self-hosted family location tracker)';

  /// Forward geocodes [query] (an address or place name) to a coordinate.
  /// Returns `null` when no result is found or the service is unavailable.
  static Future<LatLng?> search(String query) async {
    if (!isEnabled) return null; // Disabled unless a secure server is set.
    final Uri uri = Uri.parse('$baseUrl/search').replace(
      queryParameters: <String, String>{
        'q': query,
        'format': 'jsonv2',
        'limit': '1',
      },
    );
    try {
      final http.Response res = await http
          .get(uri, headers: <String, String>{'User-Agent': _userAgent});
      if (res.statusCode != 200) return null;
      final List<dynamic> list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) return null;
      final Map<String, dynamic> first = list.first as Map<String, dynamic>;
      final double? lat = double.tryParse(first['lat'].toString());
      final double? lon = double.tryParse(first['lon'].toString());
      if (lat == null || lon == null) return null;
      return LatLng(lat, lon);
    } catch (_) {
      return null;
    }
  }

  /// Reverse geocodes [position] to a human-readable address string.
  /// Returns `null` when the service is unavailable.
  static Future<String?> reverse(LatLng position) async {
    if (!isEnabled) return null; // Disabled unless a secure server is set.
    final Uri uri = Uri.parse('$baseUrl/reverse').replace(
      queryParameters: <String, String>{
        'lat': position.latitude.toString(),
        'lon': position.longitude.toString(),
        'format': 'jsonv2',
      },
    );
    try {
      final http.Response res = await http
          .get(uri, headers: <String, String>{'User-Agent': _userAgent});
      if (res.statusCode != 200) return null;
      final Map<String, dynamic> map =
          jsonDecode(res.body) as Map<String, dynamic>;
      return map['display_name'] as String?;
    } catch (_) {
      return null;
    }
  }
}
