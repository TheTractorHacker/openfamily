import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Credentials the background location isolate needs: the API base URL, the
/// device id and the **device ingest key**.
///
/// The ingest key is a write-only, device-scoped credential that authorizes
/// only `POST /locations`, `POST /locations/batch` and `POST /devices/heartbeat`.
/// It lives in the platform secure store (Android Keystore-backed
/// EncryptedSharedPreferences / iOS Keychain), never in SharedPreferences
/// (audit finding MOB-002). On iOS the item uses the
/// `first_unlock_this_device` accessibility class so the headless isolate can
/// read it while the phone is locked (after the first unlock since boot) and
/// the item is excluded from backups / device migration.
///
/// The background isolate does NOT receive the access token or the refresh
/// token. If the ingest key is rejected or missing, background reporting
/// pauses until the app is opened and re-provisions a key.
///
/// A dedicated secure-storage namespace (separate Android prefs file / iOS
/// account name) keeps these values apart from the foreground [TokenStorage]
/// entries.
class BackgroundCredentialStore {
  BackgroundCredentialStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'openfamily_bg_credentials',
      preferencesKeyPrefix: 'bg_',
    ),
    iOptions: IOSOptions(
      accountName: 'openfamily_bg_credentials',
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const String _apiBaseUrlKey = 'api_base_url';
  static const String _deviceIdKey = 'device_id';
  static const String _ingestKeyKey = 'ingest_key';

  // Legacy SharedPreferences keys written by older builds. The access-token,
  // device-id and ingest-key entries are plaintext leftovers that
  // [migrateLegacyPrefs] copies (device id / ingest key) and then deletes.
  // `wb_api_base_url` is deliberately NOT listed: it now belongs exclusively
  // to ServerConfig (the user's chosen server) and must never be removed here
  // (MOB-005).
  static const String _legacyAccessTokenKey = 'wb_access_token';
  static const String _legacyDeviceIdKey = 'wb_device_id';
  static const String _legacyIngestKeyKey = 'wb_ingest_key';

  /// One-time migration from the plaintext SharedPreferences mirror used by
  /// earlier builds. Copies the device id and ingest key into secure storage
  /// (when not already present) and deletes every legacy plaintext key,
  /// including the access token. Safe to call repeatedly and from either
  /// isolate; never throws.
  static Future<void> migrateLegacyPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final String? legacyDevice = prefs.getString(_legacyDeviceIdKey);
      final String? legacyKey = prefs.getString(_legacyIngestKeyKey);
      final bool hasLegacy = prefs.containsKey(_legacyAccessTokenKey) ||
          legacyDevice != null ||
          legacyKey != null;
      if (!hasLegacy) return;

      if (legacyKey != null &&
          legacyKey.isNotEmpty &&
          (await readIngestKey() ?? '').isEmpty) {
        await saveIngestKey(legacyKey);
      }
      if (legacyDevice != null &&
          legacyDevice.isNotEmpty &&
          (await readDeviceId() ?? '').isEmpty) {
        await saveDeviceId(legacyDevice);
      }
      // Only delete plaintext once the secure copy is confirmed (or there was
      // nothing to copy).
      final bool keyOk = legacyKey == null ||
          legacyKey.isEmpty ||
          (await readIngestKey() ?? '').isNotEmpty;
      final bool deviceOk = legacyDevice == null ||
          legacyDevice.isEmpty ||
          (await readDeviceId() ?? '').isNotEmpty;
      // The access token is always removed: it is never needed any more.
      await prefs.remove(_legacyAccessTokenKey);
      if (keyOk && deviceOk) {
        await prefs.remove(_legacyDeviceIdKey);
        await prefs.remove(_legacyIngestKeyKey);
      }
    } catch (_) {
      // Migration is best-effort; it retries on the next start.
    }
  }

  /// Writes the background-visible, non-secret-ish values to secure storage.
  static Future<void> sync({
    required String apiBaseUrl,
    required String deviceId,
  }) async {
    await _storage.write(key: _apiBaseUrlKey, value: apiBaseUrl);
    if (deviceId.isNotEmpty) {
      await _storage.write(key: _deviceIdKey, value: deviceId);
    }
  }

  /// Removes all background credentials. Does not touch ServerConfig's URL.
  static Future<void> clear() async {
    await _storage.delete(key: _apiBaseUrlKey);
    await _storage.delete(key: _deviceIdKey);
    await _storage.delete(key: _ingestKeyKey);
    // Also purge any plaintext leftovers from older builds.
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyAccessTokenKey);
    await prefs.remove(_legacyDeviceIdKey);
    await prefs.remove(_legacyIngestKeyKey);
  }

  static Future<String?> readApiBaseUrl() => _storage.read(key: _apiBaseUrlKey);

  static Future<String?> readDeviceId() => _storage.read(key: _deviceIdKey);

  /// Persists the device id (called from the foreground app after registration).
  static Future<void> saveDeviceId(String id) =>
      _storage.write(key: _deviceIdKey, value: id);

  /// Persists the device ingest key (returned once at registration or after a
  /// rotation).
  static Future<void> saveIngestKey(String key) =>
      _storage.write(key: _ingestKeyKey, value: key);

  static Future<String?> readIngestKey() => _storage.read(key: _ingestKeyKey);
}
