import 'dart:async';

import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/geocoding_service.dart';

/// Scriptable [GeocodingBackend] for unit and widget tests.
class FakeGeocodingBackend implements GeocodingBackend {
  final List<String> suggestQueries = <String>[];
  final List<LatLng> reverseCalls = <LatLng>[];

  /// Completers let tests resolve responses out of order.
  Future<List<GeocodeSuggestion>> Function(String q)? onSuggest;
  Future<String?> Function(LatLng p)? onReverse;

  List<GeocodeSuggestion> results = const <GeocodeSuggestion>[];
  String? reverseResult;
  GeocodeFailure? failure;

  @override
  Future<List<GeocodeSuggestion>> suggest(
    String query, {
    LatLng? near,
    bool explicit = false,
    int limit = 5,
  }) async {
    suggestQueries.add(query);
    if (onSuggest != null) return onSuggest!(query);
    if (failure != null) throw GeocodeException(failure!);
    return results;
  }

  @override
  Future<String?> reverse(LatLng position) async {
    reverseCalls.add(position);
    if (onReverse != null) return onReverse!(position);
    if (failure != null) throw GeocodeException(failure!);
    return reverseResult;
  }
}

const GeocodeSuggestion kMainStreet = GeocodeSuggestion(
  label: '123 Main St, Springfield, IL',
  name: '123 Main St',
  position: LatLng(39.7990, -89.6501),
  type: 'house',
);
const GeocodeSuggestion kLibrary = GeocodeSuggestion(
  label: 'Lincoln Library, 500 E Monroe St, Springfield, IL',
  name: 'Lincoln Library',
  position: LatLng(39.7983, -89.6544),
  type: 'poi',
);
