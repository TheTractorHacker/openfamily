import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_credential_store.dart';
import 'biometric_service.dart';
import 'location_outbox.dart';
import 'offline/offline_sync.dart';
import 'server_config.dart';
import 'session_diary.dart';
import 'session_gate.dart';
import 'storage_event_log.dart';

/// One stored token pair as read from a single backing store.
class StoredSession {
  const StoredSession({
    required this.source,
    required this.access,
    required this.refresh,
  });

  /// 'A' (EncryptedSharedPreferences), 'B' (independent Keystore store) or
  /// 'D' (plain app-private preferences, the copy that survives an update).
  final String source;
  final String? access;
  final String? refresh;

  DateTime? get refreshIssuedAt =>
      refresh == null ? null : jwtIssuedAtOf(refresh!);
}

/// Whether the saved-login fallback can work on this phone.
enum KeepSignedInStatus {
  /// The switch is off; nothing is saved.
  off,

  /// A password is saved and will be used if the server ends the session.
  active,

  /// On, but the last sign-in needed a two-factor code, so nothing can be saved.
  twoFactor,

  /// On, but nothing is saved yet: it is saved at the next password sign-in.
  waitingForSignIn,
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
    aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: false),
  );

  static const FlutterSecureStorage _storageB = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      sharedPreferencesName: 'openfamily_session_b',
      preferencesKeyPrefix: 'sb_',
    ),
  );

  static const FlutterSecureStorage _storageC = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
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
  // Set when the last password login needed a two-factor code: such a login
  // cannot be repeated without the person, so nothing is saved for it.
  static const String _twoFactorLoginPref = 'last_login_used_two_factor';
  static const String _deviceIdKey = 'device_id';

  // Store D: ordinary app-private SharedPreferences. Production incident: the
  // server address (plain prefs) survived every app update while all
  // Keystore-wrapped copies (A, B and the saved login) were lost, so the user
  // had to sign in again after each update. Android's per-app sandbox protects
  // this file (backups are disabled), the same protection every app's plain
  // data gets; it is the last resort when the Keystore stores come back empty.
  static const String _prefAccessKey = 'wb_session_access';
  static const String _prefRefreshKey = 'wb_session_refresh';
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

  /// Read errors seen by the current [readAllStores] pass (store letter ->
  /// exception type). A store that throws is "unavailable", never "empty".
  static final Map<String, String> _readErrors = <String, String>{};

  /// Store letters that failed during the last [readAllStores] (after retries).
  static Map<String, String> get lastReadErrors => Map<String, String>.unmodifiable(_readErrors);

  /// Test seam: replaces the delays between whole-store re-reads.
  static List<Duration> retryDelays = const <Duration>[
    Duration(milliseconds: 200),
    Duration(milliseconds: 600),
  ];

  /// Short hashes of refresh tokens this phone has already used up, kept across restarts (and shared by every
  /// isolate through the plain preferences file). A refresh token is single-use, and the server treats a used one
  /// coming back as theft and revokes the whole session. Production incident: an update restarted the app while an
  /// older copy of the refresh token was still in one store; it was presented before the live one and signed the
  /// owner out. A token this phone replaced or used is therefore never presented again.
  static const String _spentKey = 'wb_spent_refresh';
  static const int _spentMax = 24;

  /// Adds the persisted spent tokens to the in-memory rejected set. Never throws.
  static Future<void> _loadSpent() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _rejected.addAll(prefs.getStringList(_spentKey) ?? const <String>[]);
    } catch (_) {}
  }

  static DateTime? _lastSignoutLoggedAt;
  static String _lastSignoutReason = '';

  /// Remembers that [refresh] has been used (or replaced) and must never be presented again. Never throws.
  static Future<void> markSpent(String refresh) async {
    if (refresh.isEmpty) return;
    final String h = SessionDiary.shortHash(refresh);
    _rejected.add(h);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final List<String> list = List<String>.of(prefs.getStringList(_spentKey) ?? const <String>[]);
      if (list.contains(h)) return;
      list.add(h);
      while (list.length > _spentMax) {
        list.removeAt(0);
      }
      await prefs.setStringList(_spentKey, list);
      _diary.record('spent', 'refresh=$h');
    } catch (_) {}
  }

  /// Whose background credentials were kept when the session merely ran out (see [clear]). Plain preferences, so
  /// the next sign-in (any isolate) can compare accounts.
  static const String _keptForUserKey = 'wb_bg_kept_for_user';

  /// The account id (`uid` claim) of whatever token is held right now, or null.
  static Future<String?> _heldUserId() async {
    try {
      for (final StoredSession h in <StoredSession>[if (_mem != null) _mem!, ...await readAllStores()]) {
        for (final String? t in <String?>[h.access, h.refresh]) {
          final String? uid = (t == null || t.isEmpty) ? null : jwtUserIdOf(t);
          if (uid != null) return uid;
        }
      }
    } catch (_) {}
    return null;
  }

  /// A session that merely ran out keeps the phone reporting in the background (the device key and id stay). This
  /// runs on the next sign-in: the same person simply carries on; a DIFFERENT account must inherit nothing of the
  /// previous one (device, key, queued positions). Never throws.
  static Future<void> _reconcileKeptBackground(String access) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final String? kept = prefs.getString(_keptForUserKey);
      if (kept == null) return;
      await prefs.remove(_keptForUserKey);
      final String? uid = jwtUserIdOf(access);
      if (uid != null && uid == kept) return;
      await BackgroundCredentialStore.clear();
      await LocationOutbox.clear();
      await _storage.delete(key: _deviceIdKey);
      _diary.record('bg_creds', 'cleared: a different account signed in');
    } catch (_) {}
  }

  /// Marks every stored refresh token that was issued strictly BEFORE [newRefresh] as spent: it was replaced by
  /// this save. Tokens with an unknown or equal issue time are left alone (never mark a live token).
  static Future<void> _spendReplaced(String newRefresh, List<StoredSession> before) async {
    try {
      final DateTime? newIat = StoredSession(source: 'N', access: null, refresh: newRefresh).refreshIssuedAt;
      if (newIat == null) return;
      // [before] is what the phone held in memory and in the plain file just before this save (the plain file is
      // overwritten by it); the Keystore stores are read now, with a time limit: a stuck one must not block.
      List<StoredSession> stores = const <StoredSession>[];
      try {
        stores = await readAllStores().timeout(storeTimeout * 3);
      } catch (_) {}
      final List<StoredSession> held = <StoredSession>[...before, ...stores];
      for (final StoredSession h in held) {
        final String? r = h.refresh;
        if (r == null || r.isEmpty || r == newRefresh) continue;
        final DateTime? iat = h.refreshIssuedAt;
        if (iat != null && iat.isBefore(newIat)) await markSpent(r);
      }
    } catch (_) {}
  }

  /// How long any single call into a Keystore-backed store may take before it is treated as failed. A stuck store
  /// (seen on a Samsung phone) can hang forever instead of throwing; a hang while saving a refreshed token used
  /// to stop the reliable plain-file copy from ever being written, so the server had rotated the token and the
  /// phone kept the spent one. A test seam.
  static Duration storeTimeout = const Duration(seconds: 5);

  static Future<String?> _safeRead(FlutterSecureStorage s, String key, [String store = '?']) async {
    try {
      return await s.read(key: key).timeout(storeTimeout);
    } catch (e) {
      _readErrors[store] = e.runtimeType.toString();
      return null;
    }
  }

  static Future<bool> _writePrefs(String access, String refresh) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefAccessKey, access);
      await prefs.setString(_prefRefreshKey, refresh);
      return prefs.getString(_prefRefreshKey) == refresh;
    } catch (e) {
      _diary.record('write_error', 'store=D ${e.runtimeType}');
      return false;
    }
  }

  static Future<StoredSession> _readPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // Every isolate caches this file in memory. Production incident: the background/push isolate read the pair
      // from its stale cache and presented a refresh token the UI isolate had already used.
      await prefs.reload();
      return StoredSession(
        source: 'D',
        access: prefs.getString(_prefAccessKey),
        refresh: prefs.getString(_prefRefreshKey),
      );
    } catch (e) {
      _readErrors['D'] = e.runtimeType.toString();
      return const StoredSession(source: 'D', access: null, refresh: null);
    }
  }

  static Future<void> _clearPrefs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefAccessKey);
    await prefs.remove(_prefRefreshKey);
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

  /// Time-bounded verified write of one Keystore-backed store: a hang counts as a failed write.
  static Future<bool> _boundedWrite(Future<bool> write, String store) => write.timeout(storeTimeout, onTimeout: () {
        _diary.record('write_timeout', 'store=$store');
        StorageEventLog.instance.record('write_timeout', store: 'tokens.$store');
        return false;
      });

  /// Persists an access + refresh token pair to every store.
  static Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    // A refresh token is single-use: the server has ALREADY rotated it when this runs, so the new one must be
    // saved before anything else can go wrong. Order matters: the plain app-private file first (instant and
    // reliable), then the two Keystore-backed stores, each with a time limit so a store that hangs cannot stop
    // the others. What this replaces is looked up afterwards, also with limits. One verified copy keeps the
    // session; none is a loud failure.
    final List<StoredSession> before = <StoredSession>[if (_mem != null) _mem!];
    try {
      before.add(await _readPrefs());
    } catch (_) {}
    _mem = StoredSession(source: 'M', access: access, refresh: refresh);
    final bool okD = await _writePrefs(access, refresh);
    final List<bool> keystore = await Future.wait(<Future<bool>>[
      _boundedWrite(_writeVerified(_storage, _accessKey, _refreshKey, access, refresh), 'A'),
      _boundedWrite(_writeVerified(_storageB, _accessKeyB, _refreshKeyB, access, refresh), 'B'),
    ]);
    final bool okA = keystore[0], okB = keystore[1];
    _diary.record('save', 'refresh=${SessionDiary.shortHash(refresh)} '
        'A=${okA ? 'ok' : 'FAIL'} B=${okB ? 'ok' : 'FAIL'} '
        'D=${okD ? 'ok' : 'FAIL'}');
    if (!okA && !okB && !okD) {
      throw StateError('Could not save the session on this device.');
    }
    await _spendReplaced(refresh, before);
    await _reconcileKeptBackground(access);
    try {
      await _storage.delete(key: _legacyAccessKey).timeout(storeTimeout);
      await _storage.delete(key: _legacyRefreshKey).timeout(storeTimeout);
    } catch (_) {}
    // The background isolate gets only the base URL and device id (plus its
    // ingest key, stored separately); it never sees these tokens (MOB-002).
    try {
      final String? deviceId = await readDeviceId().timeout(storeTimeout);
      await BackgroundCredentialStore.sync(
        apiBaseUrl: ServerConfig.instance.apiBaseUrl,
        deviceId: deviceId ?? '',
      ).timeout(storeTimeout);
    } catch (_) {}
  }

  /// Reads every store. Entries with no tokens are omitted.
  ///
  /// When nothing at all comes back but a store THREW, the read is retried a
  /// few times before the empty answer is believed: a Keystore hiccup right
  /// after an update or a reboot must not look like "signed out". Every such
  /// failure lands in the [StorageEventLog].
  static Future<List<StoredSession>> readAllStores() async {
    List<StoredSession> out = await _readAllOnce();
    for (int i = 0; out.isEmpty && _readErrors.isNotEmpty && i < retryDelays.length; i++) {
      StorageEventLog.instance.record('read_error', store: 'tokens',
          detail: '${_readErrors.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join(' ')} retry=$i');
      await Future<void>.delayed(retryDelays[i]);
      out = await _readAllOnce();
    }
    if (out.isEmpty && _readErrors.isNotEmpty) {
      StorageEventLog.instance.record('read_failed', store: 'tokens', detail: _readErrors.keys.join(','));
    }
    return out;
  }

  static Future<List<StoredSession>> _readAllOnce() async {
    _readErrors.clear();
    final List<StoredSession> out = <StoredSession>[];
    final StoredSession a = StoredSession(
      source: 'A',
      access: await _safeRead(_storage, _accessKey, 'A'),
      refresh: await _safeRead(_storage, _refreshKey, 'A'),
    );
    final StoredSession b = StoredSession(
      source: 'B',
      access: await _safeRead(_storageB, _accessKeyB, 'B'),
      refresh: await _safeRead(_storageB, _refreshKeyB, 'B'),
    );
    final StoredSession d = await _readPrefs();
    // Pre-v2 session: used only when nothing else holds a token.
    final bool haveV2 = (d.refresh ?? '').isNotEmpty ||
        (d.access ?? '').isNotEmpty ||
        (a.refresh ?? '').isNotEmpty ||
        (a.access ?? '').isNotEmpty ||
        (b.refresh ?? '').isNotEmpty ||
        (b.access ?? '').isNotEmpty;
    final StoredSession? legacy = haveV2
        ? null
        : StoredSession(
            source: 'L',
            access: await _safeRead(_storage, _legacyAccessKey, 'L'),
            refresh: await _safeRead(_storage, _legacyRefreshKey, 'L'),
          );
    for (final StoredSession s in <StoredSession>[
      a,
      b,
      d,
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
    await _loadSpent();
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

  /// Another isolate may have rotated the pair since this one last saved: re-reads every store and makes the
  /// newest pair this isolate's own (so its access token matches). Returns the newest refresh token, or null.
  static Future<String?> adoptNewestStored() async {
    final List<StoredSession> ranked = await _ranked();
    for (final StoredSession s in ranked) {
      final String? r = s.refresh;
      if (r == null || r.isEmpty || isRejected(r)) continue;
      if (s.source != 'M') _mem = StoredSession(source: 'M', access: s.access, refresh: r);
      return r;
    }
    return null;
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
    _lastSignoutLoggedAt = null;
    _lastSignoutReason = '';
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
      // A token this phone already used is dead: a store that cannot be cleaned (a stuck Keystore file) must not
      // make the phone believe it still has a session, nor offer that token to the server again.
      if ((s.refresh ?? '').isNotEmpty && !isRejected(s.refresh!)) return s.refresh;
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
    if (credentials.any((String? credential) => credential != null && credential.isNotEmpty)) return true;
    // A store that could not be read may still hold the session: assume it does (keeps the app lock and the
    // biometric opt-in in place) rather than treating a storage error as "signed out".
    return _readErrors.isNotEmpty;
  }

  /// Removes all stored tokens AND the device id (full session teardown).
  ///
  /// The device id is tied to the authenticated user, so it must be cleared
  /// whenever tokens are cleared — otherwise a later login by a different user
  /// would reuse the previous user's device id.
  static Future<bool> clear({String reason = 'unspecified', bool keepOfflineData = false}) async {
    _diary.record('clear', 'reason=$reason');
    // The same sign-out from many concurrent callers (a dead session makes every request fail at once) is logged
    // once per minute: the log keeps only the last 50 events and the storm pushed out everything else.
    final DateTime nowT = DateTime.now();
    final DateTime? lastAt = _lastSignoutLoggedAt;
    if (reason != _lastSignoutReason || lastAt == null || nowT.difference(lastAt) > const Duration(minutes: 1)) {
      StorageEventLog.instance.record('signout', store: 'tokens', detail: 'reason=$reason');
      _lastSignoutLoggedAt = nowT;
      _lastSignoutReason = reason;
    }
    // A store that ignores deletes (seen on a Samsung phone) keeps its old token after this teardown. Remember
    // every token held now as dead, so it is never offered to the server or mistaken for a session again.
    try {
      for (final StoredSession h in <StoredSession>[...await readAllStores(), if (_mem != null) _mem!]) {
        final String? r = h.refresh;
        if (r != null && r.isNotEmpty) await markSpent(r);
      }
    } catch (_) {}
    // A session that merely ran out (keepOfflineData) is not a sign-out: the phone keeps reporting its position in
    // the background with its device key, so the family's map stays current until the person signs in again.
    // Only an explicit sign-out removes the device key. Whose credentials these are is remembered so a different
    // account signing in next inherits none of them ([_reconcileKeptBackground]).
    String? keepFor;
    if (keepOfflineData) {
      keepFor = await _heldUserId();
      if (keepFor != null) {
        try {
          final SharedPreferences prefs = await SharedPreferences.getInstance();
          await prefs.setString(_keptForUserKey, keepFor);
        } catch (_) {
          keepFor = null;
        }
      }
    }
    final bool keepBackground = keepFor != null;
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
    await attempt(_clearPrefs);
    await attempt(clearSavedCredentials);
    if (!keepBackground) await attempt(() => _storage.delete(key: _deviceIdKey));
    await attempt(removeLegacyProfilePhotoPath);
    if (!keepBackground) await attempt(BackgroundCredentialStore.clear);
    // The offline backfill queue holds points reported under THIS device
    // identity; after teardown they would reference a dead device id and
    // pin the queue (mixed-device batches are rejected server-side), so the
    // cache lifecycle is tied to the session it was created in.
    if (!keepBackground) await attempt(LocationOutbox.clear);
    // Same for the local-first snapshot and the store-and-forward queue (docs/design/OFFLINE_RESILIENCE.md):
    // they belong to the account that created them.
    // A session that merely ran out (not a sign-out) keeps what is waiting to be sent: an SOS or a check-in
    // must reach the family after the person signs in again. A different account clears it on sign-in.
    if (!keepOfflineData) await attempt(OfflineSync.clearAll);

    try {
      final List<String?> remaining = <String?>[
        await readAccessToken(),
        await readRefreshToken(),
        await _safeRead(_storageC, _credPasswordKey),
        (await _readPrefs()).refresh,
        if (!keepBackground) await readDeviceId(),
        if (!keepBackground) await BackgroundCredentialStore.readApiBaseUrl(),
        if (!keepBackground) await BackgroundCredentialStore.readDeviceId(),
        if (!keepBackground) await BackgroundCredentialStore.readIngestKey(),
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

  /// Records whether the last password login needed a two-factor code. The
  /// saved login cannot complete such a login, so Settings says so honestly.
  static Future<void> setLastLoginUsedTwoFactor(bool used) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_twoFactorLoginPref, used);
  }

  static Future<bool> lastLoginUsedTwoFactor() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_twoFactorLoginPref) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// What "Keep me signed in" really does right now (Settings shows it).
  static Future<KeepSignedInStatus> keepSignedInStatus() async {
    if (!await keepSignedInEnabled()) return KeepSignedInStatus.off;
    if (await readCredentials() != null) return KeepSignedInStatus.active;
    return await lastLoginUsedTwoFactor()
        ? KeepSignedInStatus.twoFactor
        : KeepSignedInStatus.waitingForSignIn;
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
