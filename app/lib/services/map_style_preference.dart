import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which base map look the user wants, independent of the app theme.
enum MapStylePreference {
  /// Always the light map (the default).
  light,

  /// Always the dark map.
  dark,

  /// Follow the app theme (Ice / Night).
  matchApp,
}

extension MapStylePreferenceX on MapStylePreference {
  static MapStylePreference parse(String? raw) {
    switch (raw) {
      case 'dark':
        return MapStylePreference.dark;
      case 'match_app':
        return MapStylePreference.matchApp;
      case 'light':
      default:
        return MapStylePreference.light;
    }
  }

  String get storageValue {
    switch (this) {
      case MapStylePreference.light:
        return 'light';
      case MapStylePreference.dark:
        return 'dark';
      case MapStylePreference.matchApp:
        return 'match_app';
    }
  }

  /// Whether the dark map style applies, given the app theme's brightness.
  bool resolveDark({required bool appIsDark}) {
    switch (this) {
      case MapStylePreference.light:
        return false;
      case MapStylePreference.dark:
        return true;
      case MapStylePreference.matchApp:
        return appIsDark;
    }
  }
}

/// Persists the map look and notifies the map so it swaps live.
class MapStylePreferenceService {
  MapStylePreferenceService._();

  static const String _key = 'map_style_preference';

  static final ValueNotifier<MapStylePreference> preference =
      ValueNotifier<MapStylePreference>(MapStylePreference.light);

  static Future<MapStylePreference> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      preference.value = MapStylePreferenceX.parse(prefs.getString(_key));
    } catch (_) {
      preference.value = MapStylePreference.light;
    }
    return preference.value;
  }

  static Future<void> setPreference(MapStylePreference value) async {
    preference.value = value;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value.storageValue);
    } catch (_) {
      // The in-memory value still applies for this session.
    }
  }
}
