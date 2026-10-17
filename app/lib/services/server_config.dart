// Runtime server configuration for the OpenFamily app.
//
// The API base URL comes from:
//   1. A value the user saved in `shared_preferences` (generic APK / Settings).
//   2. An optional HTTPS compile-time `--dart-define=OPENFAMILY_API_URL` hint
//      when nothing is stored yet. A dart-define never locks the URL.

import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'secure_url.dart';

const String _kPrefKey = 'wb_api_base_url';

/// Singleton that holds the resolved API base URL.
class ServerConfig {
  ServerConfig._();

  static final ServerConfig instance = ServerConfig._();

  String _apiBaseUrl = '';
  bool _loaded = false;

  /// The resolved API base URL (no trailing slash).
  String get apiBaseUrl => _apiBaseUrl;

  /// Whether a non-empty URL is configured.
  bool get isConfigured => _apiBaseUrl.isNotEmpty;

  /// Loads a stored HTTPS URL. A dart-define is only a secure first-launch hint.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kPrefKey) ?? '';
    final String? secureStored = normalizeHttpsBaseUrl(stored);
    if (secureStored != null) {
      _apiBaseUrl = secureStored;
      return;
    }
    if (stored.isNotEmpty) {
      await prefs.remove(_kPrefKey);
    }
    _apiBaseUrl = normalizeHttpsBaseUrl(kApiBaseUrl) ?? '';
  }

  /// Persists a user-entered URL and updates the live value.
  Future<void> setUrl(String url) async {
    final String? cleaned = normalizeHttpsBaseUrl(url);
    if (cleaned == null) {
      throw ArgumentError.value(url, 'url', 'A valid HTTPS URL is required.');
    }
    _apiBaseUrl = cleaned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefKey, cleaned);
  }

  /// Clears the stored URL (used when the user wants to pick a new server).
  Future<void> clear() async {
    _apiBaseUrl = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPrefKey);
  }

  /// For tests: reset the in-memory singleton without touching disk.
  void debugReset() {
    _apiBaseUrl = '';
    _loaded = false;
  }
}
