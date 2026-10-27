import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/accent.dart';

/// Which accent color the app uses.
///
/// Precedence: the person's own pick, then the server operator's default,
/// then the built-in green (null).
class AccentPreferenceService {
  AccentPreferenceService._();

  static const String _key = 'accent_color';
  static const String _serverKey = 'server_accent_color';

  /// The person's pick; null means "use the server default".
  static final ValueNotifier<Color?> user = ValueNotifier<Color?>(null);

  /// Operator default from `/config` (`default_accent`); null when unset.
  static final ValueNotifier<Color?> server = ValueNotifier<Color?>(null);

  /// What the theme should use right now; null means the built-in green.
  static final ValueNotifier<Color?> effective = ValueNotifier<Color?>(null);

  static void _recompute() => effective.value = user.value ?? server.value;

  static Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    user.value = parseAccentHex(prefs.getString(_key));
    // Last operator default we saw, so the first frame already uses it.
    server.value = parseAccentHex(prefs.getString(_serverKey));
    _recompute();
  }

  /// Pass null to go back to the server default.
  static Future<void> setUser(Color? color) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, accentToHex(color));
    }
    user.value = color;
    _recompute();
  }

  /// Applies `default_accent` from a `/config` body; a missing or malformed
  /// value clears it.
  static void applyServer(Map<String, dynamic> cfg) {
    final Color? next = parseAccentHex(cfg['default_accent']);
    server.value = next;
    _recompute();
    SharedPreferences.getInstance().then((SharedPreferences p) {
      if (next == null) {
        p.remove(_serverKey);
      } else {
        p.setString(_serverKey, accentToHex(next));
      }
    }).catchError((Object _) {});
  }
}
