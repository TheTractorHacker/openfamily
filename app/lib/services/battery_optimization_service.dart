import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';

/// Guides the user to exempt Orbitly from Android battery optimization.
///
/// Doze and device-manufacturer battery managers ("deep sleep", "autostart",
/// "app standby") routinely kill or defer the plugin's foreground location
/// service once the app is backgrounded. That is the classic reason a family
/// tracker goes stale when the app "isn't open". Asking the user to set
/// Orbitly to "Don't optimize" is the standard, user-controlled fix, and
/// wireless-aware because the final choice stays with the user.
///
/// iOS has no equivalent knob (its background-location behaviour is gated by
/// `NSLocationAlwaysAndWhenInUseUsageDescription` + `UIBackgroundModes`), so
/// all the guarded methods below are Android-only no-ops elsewhere.
class BatteryOptimizationService {
  BatteryOptimizationService._();

  static const String _requestIgnoreBatteryOptimizations =
      'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS';
  static const String _ignoreBatteryOptimizationSettings =
      'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS';

  /// This app's Android package; the system dialog needs it to name Orbitly.
  static const String _package = 'app.openfamily';

  static const String _promptShownKey = 'wb_suggested_battery_optimization';

  /// Whether this platform uses Android's battery-optimization model.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Takes the person to Orbitly's own battery choice, never to a list they
  /// have to search. In order:
  ///
  /// 1. The system's one-tap dialog for THIS app ("Let Orbitly always run in
  ///    the background?"). It needs no searching: some phones (Samsung's
  ///    "Never sleeping apps" list, and the system list, which by default only
  ///    shows apps that are already exempt) do not show Orbitly where people
  ///    look. The final choice stays with the person.
  /// 2. Orbitly's app-info page, where Battery is one row away
  ///    (Settings > Apps > Orbitly > Battery > Unrestricted).
  /// 3. The general battery-optimization list.
  ///
  /// Returns true if a settings screen or dialog was opened.
  static Future<bool> openSettings() async {
    if (!isSupported) return false;
    try {
      await const AndroidIntent(
        action: _requestIgnoreBatteryOptimizations,
        data: 'package:$_package',
      ).launch();
      return true;
    } catch (_) {}
    try {
      if (await openAppSettings()) return true;
    } catch (_) {}
    try {
      await const AndroidIntent(
        action: _ignoreBatteryOptimizationSettings,
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether to surface the (one-time) "background updates may go stale"
  /// prompt. Never prompts on non-Android platforms.
  static Future<bool> shouldSuggest() async {
    if (!isSupported) return false;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_promptShownKey) ?? false);
  }

  /// Records that the battery-optimization suggestion has been shown so it
  /// does not nag on every launch.
  static Future<void> markSuggested() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_promptShownKey, true);
  }
}