import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'background_credential_store.dart';
import 'biometric_service.dart';
import 'location_outbox.dart';
import 'server_config.dart';

/// Stores auth tokens in the platform secure store:
/// - iOS: Keychain
/// - Android: Keystore-backed EncryptedSharedPreferences
class TokenStorage {
  TokenStorage._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _accessKey = 'access_token';
  static const String _refreshKey = 'refresh_token';
  static const String _deviceIdKey = 'device_id';
  // Earlier app builds kept a profile-photo *path* locally. Avatars are now
  // private server data fetched as authenticated bytes, so remove that stale
  // pointer whenever it is encountered. We intentionally do not delete the
  // file at the old path: it may be a user-owned gallery photo.
  static const String _legacyProfilePhotoPathKey = 'profile_photo_path';

  /// Persists an access + refresh token pair.
  static Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: refresh);
    // A refresh token is single-use: if the new one is not what we can read
    // back, the next refresh replays a spent token and the server ends the
    // session. Verify, retry once, and fail loudly rather than carry on.
    if (await readRefreshToken() != refresh) {
      await _storage.delete(key: _refreshKey);
      await _storage.write(key: _refreshKey, value: refresh);
      await _storage.write(key: _accessKey, value: access);
      if (await readRefreshToken() != refresh) {
        throw StateError('Could not save the session on this device.');
      }
    }
    // The background isolate gets only the base URL and device id (plus its
    // ingest key, stored separately); it never sees these tokens (MOB-002).
    final String? deviceId = await readDeviceId();
    await BackgroundCredentialStore.sync(
      apiBaseUrl: ServerConfig.instance.apiBaseUrl,
      deviceId: deviceId ?? '',
    );
  }

  /// Returns the stored access token, or null if none.
  static Future<String?> readAccessToken() => _storage.read(key: _accessKey);

  /// Returns the stored refresh token, or null if none.
  static Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  /// Whether any access or refresh credential remains in the token store.
  ///
  /// Treating even a partial pair as a session is deliberately conservative:
  /// a surviving access token may still work, and a refresh token can mint a
  /// new pair.
  static Future<bool> hasStoredSession() async {
    final List<String?> credentials = <String?>[
      await readAccessToken(),
      await readRefreshToken(),
    ];
    return credentials.any(
      (String? credential) => credential != null && credential.isNotEmpty,
    );
  }

  /// Removes all stored tokens AND the device id (full session teardown).
  ///
  /// The device id is tied to the authenticated user, so it must be cleared
  /// whenever tokens are cleared — otherwise a later login by a different user
  /// would reuse the previous user's device id.
  static Future<bool> clear() async {
    // Keep the lock enabled until every credential has been deleted and its
    // absence verified. If deletion fails or the process stops midway, any
    // surviving session therefore remains protected.
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (_) {
        // Continue clearing the other stores, then verify the final state.
      }
    }

    await attempt(() => _storage.delete(key: _accessKey));
    await attempt(() => _storage.delete(key: _refreshKey));
    await attempt(() => _storage.delete(key: _deviceIdKey));
    await attempt(removeLegacyProfilePhotoPath);
    await attempt(BackgroundCredentialStore.clear);
    // The offline backfill queue holds points reported under THIS device
    // identity; after teardown they would reference a dead device id and
    // pin the queue (mixed-device batches are rejected server-side), so the
    // cache lifecycle is tied to the session it was created in.
    await attempt(LocationOutbox.clear);

    try {
      final List<String?> remaining = <String?>[
        await readAccessToken(),
        await readRefreshToken(),
        await readDeviceId(),
        await BackgroundCredentialStore.readApiBaseUrl(),
        await BackgroundCredentialStore.readDeviceId(),
        await BackgroundCredentialStore.readIngestKey(),
      ];
      if (remaining.any((String? value) => value != null)) {
        throw StateError('One or more session credentials remain.');
      }
    } catch (_) {
      throw StateError('Could not safely clear and verify the local session.');
    }

    // A false result is safe (the session is already gone), but callers can
    // use it diagnostically. Fresh login refuses to persist a new session
    // until this flag can be reset, preventing cross-account carryover.
    return BiometricService.instance.setEnabled(false);
  }

  /// Deletes the path-only profile-photo value written by pre-avatar builds.
  ///
  /// Deletion is idempotent and deliberately leaves any referenced file alone,
  /// because the app did not own that source image.
  static Future<void> removeLegacyProfilePhotoPath() =>
      _storage.delete(key: _legacyProfilePhotoPathKey);

  /// Persists the backend device id returned by POST /devices.
  static Future<void> saveDeviceId(String id) async {
    await _storage.write(key: _deviceIdKey, value: id);
    // Mirror the device id into shared_preferences so the background isolate
    // can attach reports to the correct device.
    await BackgroundCredentialStore.saveDeviceId(id);
  }

  /// Returns the stored device id, or null if none.
  static Future<String?> readDeviceId() => _storage.read(key: _deviceIdKey);
}
