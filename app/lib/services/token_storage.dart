import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'background_credential_store.dart';
import 'biometric_service.dart';
import 'location_outbox.dart';
import 'server_config.dart';
import 'session_gate.dart' show jwtExpiryOf;

/// Stores auth tokens in the platform secure store:
/// - iOS: Keychain
/// - Android: Keystore-backed EncryptedSharedPreferences
class TokenStorage {
  TokenStorage._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // A second, independent Keystore-backed file. Some phones end up with a
  // primary store that keeps returning an old value and ignores new writes
  // (the server then sees a spent refresh token replayed after every login),
  // so the session lives in two places and the newest copy always wins.
  static const FlutterSecureStorage _backup = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'of_session_backup',
      preferencesKeyPrefix: 'of_b_',
    ),
  );

  // v2 keys: a stuck v1 entry can never shadow a fresh login.
  static const String _accessKey = 'access_token_v2';
  static const String _refreshKey = 'refresh_token_v2';
  static const String _backupAccessKey = 'b_access_token';
  static const String _backupRefreshKey = 'b_refresh_token';
  static const String _legacyAccessKey = 'access_token';
  static const String _legacyRefreshKey = 'refresh_token';
  static const String _deviceIdKey = 'device_id';
  // Earlier app builds kept a profile-photo *path* locally. Avatars are now
  // private server data fetched as authenticated bytes, so remove that stale
  // pointer whenever it is encountered. We intentionally do not delete the
  // file at the old path: it may be a user-owned gallery photo.
  static const String _legacyProfilePhotoPathKey = 'profile_photo_path';

  /// Persists an access + refresh token pair.
  ///
  /// Written to both stores. A store that cannot hold the new value is retried
  /// once; the save fails only when neither store ends up holding it, so one
  /// broken store can no longer block signing in.
  static Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    final bool primary = await _writeVerified(
      _storage,
      _accessKey,
      _refreshKey,
      access,
      refresh,
    );
    final bool secondary = await _writeVerified(
      _backup,
      _backupAccessKey,
      _backupRefreshKey,
      access,
      refresh,
    );
    if (!primary && !secondary) {
      throw StateError('Could not save the session on this device.');
    }
    // The old unversioned entries are never read once a v2 pair exists.
    try {
      await _storage.delete(key: _legacyAccessKey);
      await _storage.delete(key: _legacyRefreshKey);
    } catch (_) {}
    // The background isolate gets only the base URL and device id (plus its
    // ingest key, stored separately); it never sees these tokens (MOB-002).
    final String? deviceId = await readDeviceId();
    await BackgroundCredentialStore.sync(
      apiBaseUrl: ServerConfig.instance.apiBaseUrl,
      deviceId: deviceId ?? '',
    );
  }

  static Future<bool> _writeVerified(
    FlutterSecureStorage store,
    String accessKey,
    String refreshKey,
    String access,
    String refresh,
  ) async {
    Future<bool> attempt() async {
      try {
        await store.write(key: accessKey, value: access);
        await store.write(key: refreshKey, value: refresh);
        return await store.read(key: refreshKey) == refresh &&
            await store.read(key: accessKey) == access;
      } catch (_) {
        return false;
      }
    }

    if (await attempt()) return true;
    try {
      await store.delete(key: accessKey);
      await store.delete(key: refreshKey);
    } catch (_) {}
    return attempt();
  }

  static Future<String?> _safeRead(FlutterSecureStorage store, String key) async {
    try {
      return await store.read(key: key);
    } catch (_) {
      return null;
    }
  }

  /// The copy that expires last was issued last, so it is the newest.
  static String? _newest(List<String?> candidates) {
    String? best;
    DateTime? bestExp;
    for (final String? c in candidates) {
      if (c == null || c.isEmpty) continue;
      final DateTime? exp = jwtExpiryOf(c);
      if (best == null ||
          (exp != null && (bestExp == null || exp.isAfter(bestExp)))) {
        best = c;
        bestExp = exp;
      }
    }
    return best;
  }

  /// Returns the stored access token, or null if none.
  static Future<String?> readAccessToken() async {
    final String? v2 = _newest(<String?>[
      await _safeRead(_storage, _accessKey),
      await _safeRead(_backup, _backupAccessKey),
    ]);
    return v2 ?? await _safeRead(_storage, _legacyAccessKey);
  }

  /// Returns the stored refresh token, or null if none.
  static Future<String?> readRefreshToken() async {
    final String? v2 = _newest(<String?>[
      await _safeRead(_storage, _refreshKey),
      await _safeRead(_backup, _backupRefreshKey),
    ]);
    return v2 ?? await _safeRead(_storage, _legacyRefreshKey);
  }

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
    await attempt(() => _storage.delete(key: _legacyAccessKey));
    await attempt(() => _storage.delete(key: _legacyRefreshKey));
    await attempt(() => _backup.delete(key: _backupAccessKey));
    await attempt(() => _backup.delete(key: _backupRefreshKey));
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
