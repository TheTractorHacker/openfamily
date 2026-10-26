import 'package:shared_preferences/shared_preferences.dart';

/// Local driving-detection flags. Stored in SharedPreferences so the
/// background isolate can read them (it calls [reload] first).
///
/// Motion-sensor detection (hard braking / rapid acceleration) is ON by
/// default: a missing preference means on, for new installs and for installs
/// that update. The phone-use estimate is a separate, more intrusive switch
/// and stays OFF until the user turns it on.
class DrivingSettings {
  DrivingSettings._();

  static const String sensorKey = 'driving_sensor_enabled';
  static const String phoneUseKey = 'driving_phone_use_enabled';

  /// True once the server has acknowledged the current effective value of
  /// [sensorKey]. Cleared whenever the local value changes.
  static const String syncedKey = 'driving_sensor_server_synced';

  /// The one-time "Driving detection is on" card has been dismissed.
  static const String disclosureSeenKey = 'driving_detection_disclosure_seen';

  /// Effective state: missing preference = on. Unreadable storage = off (the
  /// safe answer when we cannot tell).
  static Future<bool> sensorEnabled({bool reload = true}) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (reload) await p.reload();
      return p.getBool(sensorKey) ?? true;
    } catch (_) {
      return false;
    }
  }

  /// Phone-use estimate (default off). Only effective when [sensorEnabled]
  /// is also true.
  static Future<bool> phoneUseEnabled({bool reload = true}) =>
      _get(phoneUseKey, reload, false);

  static Future<void> setSensorEnabled(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(sensorKey, v);
    await p.setBool(syncedKey, false);
    if (!v) await p.setBool(phoneUseKey, false);
  }

  static Future<void> setPhoneUseEnabled(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(phoneUseKey, v);
    // The server must be told again (syncOptIn resends both flags).
    await p.setBool(syncedKey, false);
  }

  static Future<bool> serverSynced({bool reload = true}) =>
      _get(syncedKey, reload, false);

  /// Persists the effective value explicitly and records that the server has
  /// been told [enabled]. Does nothing if the local value changed meanwhile,
  /// so a later sync still delivers the newer choice.
  /// [phoneUse], when given, must also still match the stored phone-use flag.
  static Future<void> markSynced(bool enabled, {bool? phoneUse}) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.reload();
    if ((p.getBool(sensorKey) ?? true) != enabled) return;
    if (phoneUse != null && (p.getBool(phoneUseKey) ?? false) != phoneUse) {
      return;
    }
    await p.setBool(sensorKey, enabled);
    await p.setBool(syncedKey, true);
  }

  static Future<bool> disclosureSeen() => _get(disclosureSeenKey, false, false);

  static Future<void> markDisclosureSeen() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setBool(disclosureSeenKey, true);
    } catch (_) {}
  }

  static Future<bool> _get(String key, bool reload, bool fallback) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (reload) await p.reload();
      return p.getBool(key) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }
}
