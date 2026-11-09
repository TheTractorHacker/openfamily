import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Wraps [geolocator] so screens can request the user's current position with
/// graceful fallback: permission denied, location services off, or a timeout
/// all resolve to `null` instead of throwing.
class LocationService {
  LocationService._();

  /// Returns the user's current position, or `null` when it can't be obtained
  /// (permission denied/denied-forever, services disabled, or a timeout).
  ///
  /// This is intentionally non-throwing so callers (the welcome hero and the
  /// place picker) can degrade to a neutral map instead of crashing.
  /// [askPermission]: false never shows a permission prompt (the map's
  /// automatic start position must not ask; the locate button may).
  static Future<LatLng?> currentPosition({bool askPermission = true}) async {
    try {
      final bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && askPermission) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      return null;
    }
  }
}
