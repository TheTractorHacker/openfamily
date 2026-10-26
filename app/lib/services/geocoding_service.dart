import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'server_features.dart';

/// One forward-geocoding hit from `GET /geocode/search`.
class GeocodeSuggestion {
  const GeocodeSuggestion({
    required this.label,
    required this.name,
    required this.position,
    required this.type,
  });

  /// Full address line to put in the address field.
  final String label;

  /// Short headline (street line or place name).
  final String name;
  final LatLng position;

  /// `house | street | city | poi` (unknown values are treated as `poi`).
  final String type;

  /// Friendly secondary text for the suggestion row.
  String get typeLabel {
    switch (type) {
      case 'house':
        return 'Address';
      case 'street':
        return 'Street';
      case 'city':
        return 'Town or area';
      default:
        return 'Place';
    }
  }

  /// Returns null for entries without a label or valid coordinates.
  static GeocodeSuggestion? tryParse(Object? json) {
    if (json is! Map) return null;
    final Object? label = json['label'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (label is! String || label.trim().isEmpty) return null;
    if (lat is! num || lon is! num) return null;
    final double la = lat.toDouble();
    final double lo = lon.toDouble();
    if (la.isNaN || lo.isNaN || la < -90 || la > 90 || lo < -180 || lo > 180) {
      return null;
    }
    final Object? name = json['name'];
    final Object? type = json['type'];
    return GeocodeSuggestion(
      label: label.trim(),
      name: name is String && name.trim().isNotEmpty ? name.trim() : label.trim(),
      position: LatLng(la, lo),
      type: type is String ? type : 'poi',
    );
  }

  /// Parses a `{"results": [...]}` body, skipping malformed entries.
  static List<GeocodeSuggestion> parseList(Object? body) {
    if (body is! Map || body['results'] is! List) return const <GeocodeSuggestion>[];
    return <GeocodeSuggestion>[
      for (final Object? e in body['results'] as List)
        if (tryParse(e) case final GeocodeSuggestion s) s,
    ];
  }
}

/// Why a lookup failed, so the UI can show friendly text.
enum GeocodeFailure { offline, rateLimited, unavailable }

class GeocodeException implements Exception {
  const GeocodeException(this.failure);
  final GeocodeFailure failure;

  @override
  String toString() => 'GeocodeException($failure)';
}

/// Transport seam so widgets/tests can fake the server.
abstract class GeocodingBackend {
  Future<List<GeocodeSuggestion>> suggest(
    String query, {
    LatLng? near,
    bool explicit = false,
    int limit = 5,
  });

  /// Returns the address for [position], or null when none was found.
  Future<String?> reverse(LatLng position);
}

/// Talks to the OpenFamily server's `/geocode/*` proxy.
///
/// PRIVACY: the phone never contacts a geocoder provider; address text and
/// coordinates go to YOUR server, which queries the configured provider (see
/// docs/maps.md). Availability comes from `GET /config` `geocoder.enabled`.
class ApiGeocodingBackend implements GeocodingBackend {
  const ApiGeocodingBackend();

  static const Duration _timeout = Duration(seconds: 8);

  @override
  Future<List<GeocodeSuggestion>> suggest(
    String query, {
    LatLng? near,
    bool explicit = false,
    int limit = 5,
  }) async {
    final Map<String, String> q = <String, String>{
      'q': query.trim(),
      'limit': '$limit',
      if (near != null) 'lat': near.latitude.toStringAsFixed(2),
      if (near != null) 'lon': near.longitude.toStringAsFixed(2),
      if (explicit) 'explicit': '1',
    };
    final Object? body = await _call(
      () => ApiClient.get('/geocode/search', query: q),
    );
    return GeocodeSuggestion.parseList(body);
  }

  @override
  Future<String?> reverse(LatLng position) async {
    try {
      final Object? body = await _call(
        () => ApiClient.get('/geocode/reverse', query: <String, String>{
          'lat': position.latitude.toStringAsFixed(5),
          'lon': position.longitude.toStringAsFixed(5),
        }),
      );
      if (body is Map && body['address'] is String) {
        final String a = (body['address'] as String).trim();
        return a.isEmpty ? null : a;
      }
      return null;
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<Object?> _call(Future<dynamic> Function() run) async {
    try {
      return await run().timeout(_timeout);
    } on ApiException catch (e) {
      if (e.status == 404) rethrow;
      throw GeocodeException(
        e.status == 429 ? GeocodeFailure.rateLimited : GeocodeFailure.unavailable,
      );
    } on SessionExpiredException {
      throw const GeocodeException(GeocodeFailure.unavailable);
    } on TimeoutException {
      throw const GeocodeException(GeocodeFailure.offline);
    } on SocketException {
      throw const GeocodeException(GeocodeFailure.offline);
    } on http.ClientException {
      throw const GeocodeException(GeocodeFailure.offline);
    }
  }
}

/// Static facade kept from the earlier Nominatim client so callers compile.
///
/// Every convenience method degrades gracefully (null / empty) when the
/// feature is off or a lookup fails; use [suggest] when the reason matters.
class GeocodingService {
  GeocodingService._();

  /// Replaceable in tests.
  static GeocodingBackend backend = const ApiGeocodingBackend();

  /// True when the server advertises a geocoder. False by default (and for
  /// older servers) so the picker falls back to plain pin-drop.
  static bool get isEnabled => ServerFeatures.instance.geocoderEnabled;

  /// True when search-as-you-type is allowed (otherwise explicit search only).
  static bool get isAutocompleteEnabled =>
      isEnabled && ServerFeatures.instance.geocoderAutocomplete;

  /// Suggestions for [query]; throws [GeocodeException] on failure.
  static Future<List<GeocodeSuggestion>> suggest(
    String query, {
    LatLng? near,
    bool explicit = false,
    int limit = 5,
  }) {
    if (!isEnabled) return Future<List<GeocodeSuggestion>>.value(const <GeocodeSuggestion>[]);
    return backend.suggest(query, near: near, explicit: explicit, limit: limit);
  }

  /// Forward geocodes [query] to its best match, or null.
  static Future<LatLng?> search(String query) async {
    try {
      final List<GeocodeSuggestion> r =
          await suggest(query, explicit: true, limit: 1);
      return r.isEmpty ? null : r.first.position;
    } catch (_) {
      return null;
    }
  }

  /// Reverse geocodes [position]; null when disabled, offline, or not found.
  static Future<String?> reverse(LatLng position) async {
    if (!isEnabled) return null;
    try {
      return await backend.reverse(position);
    } catch (_) {
      return null;
    }
  }
}
