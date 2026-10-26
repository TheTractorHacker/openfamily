import 'package:shared_preferences/shared_preferences.dart';

/// Local opt-in flags (default OFF). Stored in SharedPreferences so the
/// background isolate can read them (it calls [reload] first).
class DrivingSettings {
  DrivingSettings._();

  static const String sensorKey = 'driving_sensor_enabled';
  static const String phoneUseKey = 'driving_phone_use_enabled';

  static Future<bool> sensorEnabled({bool reload = true}) =>
      _get(sensorKey, reload);

  /// Phone-use estimate. Only effective when [sensorEnabled] is also true.
  static Future<bool> phoneUseEnabled({bool reload = true}) =>
      _get(phoneUseKey, reload);

  static Future<void> setSensorEnabled(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(sensorKey, v);
    if (!v) await p.setBool(phoneUseKey, false);
  }

  static Future<void> setPhoneUseEnabled(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(phoneUseKey, v);
  }

  static Future<bool> _get(String key, bool reload) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (reload) await p.reload();
      return p.getBool(key) ?? false;
    } catch (_) {
      return false;
    }
  }
}
