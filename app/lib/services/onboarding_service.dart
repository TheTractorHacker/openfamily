import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, per user and per device, whether the first-run walkthrough has
/// been seen. Stored in SharedPreferences (not secure storage) on purpose:
/// it is a harmless UI flag and must never touch the session/token storage.
class OnboardingService {
  OnboardingService._();

  static String _key(String userId) => 'onboarding_seen_v1_$userId';

  static Future<bool> hasSeen(String userId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(userId)) ?? false;
  }

  static Future<void> markSeen(String userId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(userId), true);
  }

  /// Process-lifetime guard so the shell asks at most once per user per run.
  static final Set<String> _checked = <String>{};

  static bool claimCheck(String userId) => _checked.add(userId);

  static void resetCheckedForTest() => _checked.clear();
}
