import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_credential_store.dart';
import 'biometric_service.dart';
import 'location_outbox.dart';
import 'server_config.dart';
import 'session_diary.dart';
import 'session_gate.dart';

/// One stored token pair as read from a single backing store.
class StoredSession {
  const StoredSession({
    required this.source,
    required this.access,
    required this.refresh,
  });

  /// 'A' (EncryptedSharedPreferences) or 'B' (independent Keystore store).
  final String source;
  final String? access;
  final String? refresh;

  DateTime? get refreshIssuedAt =>
      refresh == null ? null : jwtIssuedAtOf(refresh!);
}

/// Stores auth tokens in the platform secure store, redundantly.
///
/// Production incident: after a fresh login the app later sent an OLD (already
/// revoked) refresh token, so a storage read returned a stale value even though
/// newer writes had happened. The pair is therefore kept in two independent
/// Keystore-backed stores and, on every read, the one whose refresh JWT was
/// issued last (`iat`) wins:
/// - store A: EncryptedSharedPreferences (the original location);
/// - store B: a separate preferences file using the plugin's own Keystore
///   cipher (a different code path than A);
/// - store C: opt-in saved login credentials for the silent re-login fallback.
class TokenStorage {
  TokenStorage._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const FlutterSecureStorage _storageB = FlutterSecureStorage(
    aOptions: AndroidOptions(
      sharedPreferencesName: 'openfamily_session_b',
      preferencesKeyPrefix: 'sb_',
    ),
  );

  static const FlutterSecureStorage _storageC = FlutterSecureStorage(
    aOptions: AndroidOptions(
      sharedPreferencesName: 'openfamily_saved_login',
      preferencesKeyPrefix: 'sl_',
    ),
  );

  // v2 keys: on some phones the original 'access_token'/'refresh_token'
  // entries are stuck (reads return an old value, writes are ignored), so a
  // fresh pair can never be stored under them. They stay a read-only
  // fallback for sessions saved before v2 and are deleted on save/clear.
  static const String _accessKey = 'access_token_v2';
  static const String _refreshKey = 'refresh_token_v2';
  static const String _legacyAccessKey = 'access_token';
  static const String _legacyRefreshKey = 'refresh_token';
  // Store B and C use distinct key names too, so they never alias store A.
  static const String _accessKeyB = 'session_b_access';
  static const String _refreshKeyB = 'session_b_refresh';
  static const String _credEmailKey = 'saved_login_email';
  static const String _credPasswordKey = 'saved_login_password';
  static const String _keepSignedInPref = 'keep_signed_in_on_device';
  static const String _deviceIdKey = 'device_id';
  // Earlier app builds kept a profile-photo *path* locally. Avatars are now
  // private server data fetched as authenticated bytes, so remove that stale
  // pointer whenever it is encountered. We intentionally do not delete the
  // file at the old path: it may be a user-owned gallery photo.
  static const String _legacyProfilePhotoPathKey = 'profile_photo_path';

  /// Short hashes of refresh tokens the server definitively rejected during
  /// this process. A rejected token is never retried.
  static final Set<String> _rejected = <String>{};

  /// The pair this process last saved: authoritative for the access token on
  /// the hot path (saves four secure-storage reads per request) and one more
  /// refresh candidate. Dropped on clear.
  static StoredSession? _mem;

  static final SessionDiary _diary = SessionDiary.instance;

  static Future<String?> _safeRead(FlutterSecureStorage s, String key) async {
    try {
      return await s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _writeVerified(
    FlutterSecureStorage s,
    String accessKey,
    String refreshKey,
    String access,
    String refresh,
  ) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0) await s.delete(key: refreshKey);
        await s.write(key: accessKey, value: access);
        await s.write(key: refreshKey, value: refresh);
        final String? gotRefresh = await s.read(key: refreshKey);
        final String? gotAccess = await s.read(key: accessKey);
        if (gotRefresh == refresh && gotAccess == access) return true;
        // The store handed back something other than what was just written:
        // exactly the stale-read fault under investigation.
        _diary.record('readback_mismatch',
            'key=$refreshKey attempt=$attempt wrote=${SessionDiary.shortHash(refresh)} '
            'got=${SessionDiary.shortHash(gotRefresh)}');
      } catch (e) {
        _diary.record('write_error', 'key=$refreshKey ${e.runtimeType}');
      }
    }
    return false;
  }

  /// Persists an access + refresh token pair to both stores.
  static Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    // A refresh token is single-use: if the new one is not what we can read
    // back, the next refresh replays a spent token. Write and verify both
    // stores; one verified copy keeps the session, none is a loud failure.
    final bool okA =
        await _writeVerified(_storage, _accessKey, _refreshKey, access, refresh);
    final bool okB = await _writeVerified(
        _storageB, _accessKeyB, _refreshKeyB, access, refresh);
    _mem = StoredSession(source: 'M', access: access, refresh: refresh);
    _diary.record('save', 'refresh=${SessionDiary.shortHash(refresh)} '
        'A=${okA ? 'ok' : 'FAIL'} B=${okB ? 'ok' : 'FAIL'}');
    if (!okA && !okB) {
      throw StateError('Could not save the session on this device.');
    }
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

  /// Reads both stores. Entries with no tokens are omitted.
  static Future<List<StoredSession>> readAllStores() async {
    final List<StoredSession> out = <StoredSession>[];
    final StoredSession a = StoredSession(
      source: 'A',
      access: await _safeRead(_storage, _accessKey),
      refresh: await _safeRead(_storage, _refreshKey),
    );
    final StoredSession b = StoredSession(
      source: 'B',
      access: await _safeRead(_storageB, _accessKeyB),
      refresh: await _safeRead(_storageB, _refreshKeyB),
    );
    // Pre-v2 session: used only when nothing else holds a token.
    final bool haveV2 = (a.refresh ?? '').isNotEmpty ||
        (a.access ?? '').isNotEmpty ||
        (b.refresh ?? '').isNotEmpty ||
        (b.access ?? '').isNotEmpty;
    final StoredSession? legacy = haveV2
        ? null
        : StoredSession(
            source: 'L',
            access: await _safeRead(_storage, _legacyAccessKey),
            refresh: await _safeRead(_storage, _legacyRefreshKey),
          );
    for (final StoredSession s in <StoredSession>[
      a,
      b,
      if (legacy != null) legacy,
      if (_mem != null) _mem!,
    ]) {
      if ((s.access ?? '').isNotEmpty || (s.refresh ?? '').isNotEmpty) {
        out.add(s);
      }
    }
    return out;
  }

  static int _issuedMs(StoredSession s) =>
      s.refreshIssuedAt?.millisecondsSinceEpoch ?? 0;

  static String _describe(StoredSession s) {
    final DateTime? iat = s.refreshIssuedAt;
    final String age = iat == null
        ? 'iat?'
        : '${DateTime.now().toUtc().difference(iat).inMinutes}m';
    return '${s.source}:${SessionDiary.shortHash(s.refresh)}/$age'
        '${s.refresh != null && isRejected(s.refresh!) ? '/rejected' : ''}';
  }

  /// All stored sessions ordered best-first: not-known-rejected before
  /// rejected, then newest refresh `iat`, then store A before B.
  static Future<List<StoredSession>> _ranked() async {
    final List<StoredSession> all = await readAllStores();
    final List<StoredSession> ranked = List<StoredSession>.of(all);
    ranked.sort((StoredSession x, StoredSession y) {
      final int rx = (x.refresh != null && isRejected(x.refresh!)) ? 1 : 0;
      final int ry = (y.refresh != null && isRejected(y.refresh!)) ? 1 : 0;
      if (rx != ry) return rx - ry;
      final int t = _issuedMs(y) - _issuedMs(x);
      if (t != 0) return t;
      return x.source.compareTo(y.source);
    });
    return ranked;
  }

  /// Refresh tokens worth trying, newest first, without duplicates and
  /// without any token the server already rejected.
  static Future<List<String>> refreshCandidates() async {
    final List<StoredSession> ranked = await _ranked();
    _diary.record('read', ranked.map(_describe).join(' '));
    final List<String> out = <String>[];
    for (final StoredSession s in ranked) {
      final String? r = s.refresh;
      if (r == null || r.isEmpty || isRejected(r) || out.contains(r)) continue;
      out.add(r);
    }
    return out;
  }

  /// Remembers that the server rejected [refresh] so it is never retried.
  static void markRejected(String refresh) {
    _rejected.add(SessionDiary.shortHash(refresh));
    _diary.record('rejected', 'refresh=${SessionDiary.shortHash(refresh)}');
  }

  static bool isRejected(String refresh) =>
      _rejected.contains(SessionDiary.shortHash(refresh));

  /// Test hook: forget in-memory state.
  static void resetForTest() {
    _rejected.clear();
    _mem = null;
  }

  /// Returns the best stored access token, or null if none. It comes from the
  /// same store as the best refresh token so the pair stays consistent.
  static Future<String?> readAccessToken() async {
    final StoredSession? mem = _mem;
    if (mem != null && (mem.access ?? '').isNotEmpty) return mem.access;
    final List<StoredSession> ranked = await _ranked();
    for (final StoredSession s in ranked) {
      if ((s.access ?? '').isNotEmpty) return s.access;
    }
    return null;
  }

  /// Returns the best stored refresh token (newest `iat`), or null if none.
  static Future<String?> readRefreshToken() async {
    final StoredSession? mem = _mem;
    if (mem != null &&
        (mem.refresh ?? '').isNotEmpty &&
        !isRejected(mem.refresh!)) {
      return mem.refresh;
    }
    final List<StoredSession> ranked = await _ranked();
    for (final StoredSession s in ranked) {
      if ((s.refresh ?? '').isNotEmpty) return s.refresh;
    }
    return null;
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
  static Future<bool> clear({String reason = 'unspecified'}) async {
    _diary.record('clear', 'reason=$reason');
    _mem = null;
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
    await attempt(() => _storageB.delete(key: _accessKeyB));
    await attempt(() => _storageB.delete(key: _refreshKeyB));
    await attempt(clearSavedCredentials);
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
        await _safeRead(_storageC, _credPasswordKey),
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

  // ---- Saved login ("Keep me signed in on this device") --------------------

  /// Whether the user allows keeping the password in the Android Keystore for
  /// the silent re-login fallback. Defaults to ON.
  static Future<bool> keepSignedInEnabled() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keepSignedInPref) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Turning it off also deletes any saved password.
  static Future<void> setKeepSignedIn(bool enabled) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepSignedInPref, enabled);
    if (!enabled) await clearSavedCredentials();
    _diary.record('keep_signed_in', enabled ? 'on' : 'off');
  }

  static Future<void> saveCredentials({
    required String email,
    required String password,
  }) async {
    if (!await keepSignedInEnabled()) return;
    await _storageC.write(key: _credEmailKey, value: email);
    await _storageC.write(key: _credPasswordKey, value: password);
  }

  static Future<({String email, String password})?> readCredentials() async {
    if (!await keepSignedInEnabled()) return null;
    final String? email = await _safeRead(_storageC, _credEmailKey);
    final String? password = await _safeRead(_storageC, _credPasswordKey);
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      return null;
    }
    return (email: email, password: password);
  }

  static Future<void> clearSavedCredentials() async {
    await _storageC.delete(key: _credEmailKey);
    await _storageC.delete(key: _credPasswordKey);
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
