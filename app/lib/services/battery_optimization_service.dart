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

  static const String _ignoreBatteryOptimizationSettings =
      'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS';

  static const String _promptShownKey = 'wb_suggested_battery_optimization';

  /// Whether this platform uses Android's battery-optimization model.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Opens the system page where the user can set Orbitly to
  /// "Don't optimize". Returns true if a settings screen was opened.
  ///
  /// Prefers the general battery-optimization list (reliable across stock
  /// Android and most OEMs without needing the app's package name), falling
  /// back to the app's own settings page if that intent is unavailable.
  static Future<bool> openSettings() async {
    if (!isSupported) return false;
    try {
      await AndroidIntent(
        action: _ignoreBatteryOptimizationSettings,
      ).launch();
      return true;
    } catch (_) {
      try {
        await openAppSettings();
        return true;
      } catch (_) {
        return false;
      }
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