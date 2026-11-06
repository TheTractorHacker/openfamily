import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import 'api_client.dart';
import 'e2ee/e2ee_crypto.dart';
import 'e2ee/private_places.dart';
import 'e2ee/private_runtime.dart';

/// Client for the backend Places (geofence) endpoints.
///
/// Places are fetched, created, and deleted against the real Go backend via
/// [ApiClient].
class PlaceService {
  PlaceService._();

  /// How long a fetched place list is reused. Places change rarely, but the
  /// list used to be re-requested on every roster fetch (startup, circle
  /// switch, reconnect, resume) and again by the Places tab.
  static const Duration cacheTtl = Duration(seconds: 30);

  static List<Place>? _cache;
  static DateTime? _cachedAt;
  static Future<List<Place>>? _inFlight;

  /// Clock for the cache; tests override it.
  static DateTime Function() clock = DateTime.now;

  /// Drops the cached list (after any create / update / delete, logout).
  static void invalidateCache() {
    _cache = null;
    _cachedAt = null;
  }

  /// Fetches all places for the current family.
  ///
  /// Cached for [cacheTtl] and single-flighted; [force] always asks the
  /// server (used by the Places screen, which must show fresh data).
  static Future<List<Place>> fetchPlaces({bool force = false}) {
    final List<Place>? cached = _cache;
    final DateTime? at = _cachedAt;
    if (!force &&
        cached != null &&
        at != null &&
        clock().difference(at) < cacheTtl) {
      return Future<List<Place>>.value(List<Place>.of(cached));
    }
    final Future<List<Place>>? pending = _inFlight;
    if (!force && pending != null) {
      return pending.then((List<Place> l) => List<Place>.of(l));
    }
    final Future<List<Place>> f = _fetchFresh();
    _inFlight = f;
    f.whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    }).ignore();
    return f.then((List<Place> l) => List<Place>.of(l));
  }

  static Future<List<Place>> _fetchFresh() async {
    final dynamic data = await ApiClient.get('/family/places');
    if (data is! List) {
      throw const ApiException(0, 'Unexpected places response.');
    }
    final List<Place> places = data
        .map((dynamic e) => _fromBackend(e as Map<String, dynamic>))
        .whereType<Place>()
        .toList();
    places.addAll(await _sealedPlaces());
    _cache = places;
    _cachedAt = clock();
    return places;
  }

  /// Places of Private circles live on the phones (sealed items), not on the server.
  static Future<List<Place>> _sealedPlaces() async {
    try {
      final PrivateRuntime rt = PrivateRuntime.instance;
      return <Place>[
        for (final ({String circleId, SealedPlace place}) e in await rt.allSealedPlaces())
          Place(
            id: e.place.id,
            name: e.place.name,
            icon: Place.iconForType(e.place.type),
            address: e.place.address,
            position: LatLng(e.place.lat, e.place.lon),
            radiusMeters: e.place.radiusMeters,
            type: e.place.type,
            circleId: e.circleId,
            circleName: rt.circleName(e.circleId),
          ),
      ];
    } catch (_) {
      return <Place>[];
    }
  }

  static Future<String?> _privateTarget(String? circleId) async {
    try {
      return await PrivateRuntime.instance.privateTargetFor(circleId);
    } catch (_) {
      return null;
    }
  }

  /// Creates a place and returns the created [Place] (with its server id).
  static Future<Place> createPlace({
    required String name,
    required String type,
    required double lat,
    required double lon,
    required double radiusMeters,
    String? address,
    String? circleId,
  }) async {
    final String? priv = await _privateTarget(circleId);
    if (priv != null) {
      final SealedPlace sp = SealedPlace(
          id: E2ee.newUuid(), name: name, lat: lat, lon: lon, radiusMeters: radiusMeters, type: type, address: address ?? '');
      await PrivateRuntime.instance.savePlace(priv, sp);
      invalidateCache();
      return Place(
          id: sp.id, name: name, icon: Place.iconForType(type), address: address ?? '', position: LatLng(lat, lon),
          radiusMeters: radiusMeters, type: type, circleId: priv, circleName: PrivateRuntime.instance.circleName(priv));
    }
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
    if (circleId != null) {
      body['circle_id'] = circleId;
    }
    invalidateCache();
    final dynamic data = await ApiClient.post('/family/places', body: body);
    invalidateCache();
    final Place? place = _fromBackend(data as Map<String, dynamic>);
    if (place == null) {
      throw const ApiException(0, 'Unexpected place response.');
    }
    return place;
  }

  /// Updates a place (PATCH) and returns the saved [Place]. Only the fields
  /// passed are sent, so omitted fields are left unchanged on the server.
  /// Pass [setCircle] to change sharing: [circleId] null = whole family.
  static Future<Place> updatePlace(
    String id, {
    String? name,
    String? type,
    double? lat,
    double? lon,
    double? radiusMeters,
    String? address,
    bool setCircle = false,
    String? circleId,
  }) async {
    final String? sealedIn = await PrivateRuntime.instance.circleOfPlace(id).catchError((Object _) => null);
    if (sealedIn != null) {
      final SealedPlace old = PrivateRuntime.instance.book(sealedIn).byId(id)!;
      final SealedPlace next = SealedPlace(
          id: id, name: name ?? old.name, lat: lat ?? old.lat, lon: lon ?? old.lon,
          radiusMeters: radiusMeters ?? old.radiusMeters, type: type ?? old.type, address: address ?? old.address,
          enterNotify: old.enterNotify, exitNotify: old.exitNotify);
      await PrivateRuntime.instance.savePlace(sealedIn, next);
      invalidateCache();
      return Place(
          id: id, name: next.name, icon: Place.iconForType(next.type), address: next.address,
          position: LatLng(next.lat, next.lon), radiusMeters: next.radiusMeters, type: next.type,
          circleId: sealedIn, circleName: PrivateRuntime.instance.circleName(sealedIn));
    }
    final Map<String, dynamic> body = <String, dynamic>{
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (radiusMeters != null) 'radius_meters': radiusMeters,
      if (address != null) 'address': address,
      // Explicit null makes the place family-wide.
      if (setCircle) 'circle_id': circleId,
    };
    invalidateCache();
    final dynamic data = await ApiClient.patch('/family/places/$id', body: body);
    invalidateCache();
    final Place? place = _fromBackend(data as Map<String, dynamic>);
    if (place == null) {
      throw const ApiException(0, 'Unexpected place response.');
    }
    return place;
  }

  /// Deletes a place by id.
  static Future<void> deletePlace(String id) async {
    final String? sealedIn = await PrivateRuntime.instance.circleOfPlace(id).catchError((Object _) => null);
    if (sealedIn != null) {
      final SealedPlace old = PrivateRuntime.instance.book(sealedIn).byId(id)!;
      await PrivateRuntime.instance.deletePlace(sealedIn, old);
      invalidateCache();
      return;
    }
    invalidateCache();
    await ApiClient.delete('/family/places/$id');
    invalidateCache();
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
      circleId: json['circle_id'] as String?,
      circleName: json['circle_name'] as String?,
    );
  }
}
