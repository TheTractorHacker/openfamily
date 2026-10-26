import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import 'api_client.dart';

/// Client for the backend Places (geofence) endpoints.
///
/// Places are fetched, created, and deleted against the real Go backend via
/// [ApiClient].
class PlaceService {
  PlaceService._();

  /// Fetches all places for the current family.
  static Future<List<Place>> fetchPlaces() async {
    final dynamic data = await ApiClient.get('/family/places');
    if (data is! List) {
      throw const ApiException(0, 'Unexpected places response.');
    }
    return data
        .map((dynamic e) => _fromBackend(e as Map<String, dynamic>))
        .whereType<Place>()
        .toList();
  }

  /// Creates a place and returns the created [Place] (with its server id).
  static Future<Place> createPlace({
    required String name,
    required String type,
    required double lat,
    required double lon,
    required double radiusMeters,
    String? address,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'name': name,
      'type': type,
      'lat': lat,
      'lon': lon,
      'radius_meters': radiusMeters,
    };
    if (address != null && address.isNotEmpty) {
      body['address'] = address;
    }
    final dynamic data = await ApiClient.post('/family/places', body: body);
    final Place? place = _fromBackend(data as Map<String, dynamic>);
    if (place == null) {
      throw const ApiException(0, 'Unexpected place response.');
    }
    return place;
  }

  /// Updates a place (PATCH) and returns the saved [Place]. Only the fields
  /// passed are sent, so omitted fields are left unchanged on the server.
  static Future<Place> updatePlace(
    String id, {
    String? name,
    String? type,
    double? lat,
    double? lon,
    double? radiusMeters,
    String? address,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (radiusMeters != null) 'radius_meters': radiusMeters,
      if (address != null) 'address': address,
    };
    final dynamic data = await ApiClient.patch('/family/places/$id', body: body);
    final Place? place = _fromBackend(data as Map<String, dynamic>);
    if (place == null) {
      throw const ApiException(0, 'Unexpected place response.');
    }
    return place;
  }

  /// Deletes a place by id.
  static Future<void> deletePlace(String id) async {
    await ApiClient.delete('/family/places/$id');
  }

  /// Maps backend JSON to a [Place], or null when required fields are missing.
  static Place? _fromBackend(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    final String? name = json['name'] as String?;
    final num? lat = json['lat'] as num?;
    final num? lon = json['lon'] as num?;
    if (id == null || name == null || lat == null || lon == null) {
      return null;
    }
    final String type = json['type'] as String? ?? 'custom';
    return Place(
      id: id,
      name: name,
      icon: Place.iconForType(type),
      address: json['address'] as String? ?? '',
      position: LatLng(lat.toDouble(), lon.toDouble()),
      radiusMeters: (json['radius_meters'] as num?)?.toDouble() ??
          kMinPlaceRadiusMeters,
      type: type,
      alertsOn: false,
    );
  }
}
