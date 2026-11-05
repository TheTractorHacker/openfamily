import 'api_client.dart';
import 'speed_units.dart';

/// Mirrors the distance/speed unit choice to the server so server-written
/// text (weekly summary and drive pushes) uses it, and reads it back on a new
/// phone. All failures are swallowed: the local choice always works offline.
class UnitsSync {
  UnitsSync._();

  /// Call once at startup: local changes are PUT to `/me/notifications`.
  static void install() {
    UnitPreferenceService.onUserChange = (UnitSystem u) async {
      await ApiClient.putJson('/me/notifications',
          body: <String, Object?>{'units': u.name});
    };
  }

  /// Reads this person's saved choice (call once signed in).
  static Future<void> pull() async {
    try {
      final dynamic d = await ApiClient.get('/me/notifications');
      if (d is Map<String, dynamic>) {
        UnitPreferenceService.applyServerChoice(parseUnitSystem(d['units']));
      }
    } catch (_) {}
  }
}
