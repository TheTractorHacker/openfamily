import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage_event_log.dart';

/// Where the wrapping key lives. `strongBox` / `tee` are Android Keystore
/// levels; `secureEnclave` / `keychain` are the iOS equivalents (Secure
/// Enclave private key vs. a software key held in the Keychain, which is what
/// the Simulator and any device without a Secure Enclave report).
enum KeystoreLevel { strongBox, tee, secureEnclave, keychain, software, unavailable }

class KeystoreStatus {
  const KeystoreStatus({
    required this.level,
    this.unlockedDeviceRequired = false,
    this.userAuthRequired = false,
    this.legacyKey = false,
  });
  final KeystoreLevel level;

  /// True only for the opt-in strict mode (or an old v1 key): the key refuses to work while the phone is locked.
  final bool unlockedDeviceRequired;
  final bool userAuthRequired;

  /// Android: the pre-0.24.2 wrapping key (unlocked-device-only) still exists, so some blobs may need re-wrapping.
  final bool legacyKey;

  /// True when the keys can be used by the background service with the screen locked.
  bool get usableWhileLocked => level != KeystoreLevel.unavailable && !unlockedDeviceRequired && !userAuthRequired;

  String get label {
    switch (level) {
      case KeystoreLevel.strongBox:
        return 'StrongBox (dedicated security chip)';
      case KeystoreLevel.tee:
        return 'Trusted Execution Environment (TEE)';
      case KeystoreLevel.secureEnclave:
        return 'Secure Enclave (dedicated security chip)';
      case KeystoreLevel.keychain:
        return 'iOS Keychain, software key (no Secure Enclave)';
      case KeystoreLevel.software:
        return 'Software only (no secure hardware on this phone)';
      case KeystoreLevel.unavailable:
        return 'Not available on this platform';
    }
  }
}

/// Thrown when the Keystore wrapping key was invalidated (screen lock removed,
/// biometrics changed with a bound key, app data restored). The stored private
/// keys cannot be read any more: fail closed and restore from the recovery
/// phrase instead of silently generating a different identity.
class VaultInvalidatedException implements Exception {
  const VaultInvalidatedException();
  @override
  String toString() => 'VaultInvalidatedException: the device key store was invalidated';
}

/// The key exists but cannot be used right now (the old Keystore key only works while the phone is unlocked).
/// NOT a loss: never regenerate anything because of this, try again later.
class VaultLockedException implements Exception {
  const VaultLockedException();
  @override
  String toString() => 'VaultLockedException: the key is not usable while the phone is locked';
}

/// Outcome of [SecureVault.migrateLegacy].
enum VaultMigration { notNeeded, done, waitingForUnlock, failedKept }

/// Storage for the secrets of this phone (identity seed, circle keys).
abstract class E2eeVault {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List value);
  Future<void> delete(String name);
  Future<List<String>> names();
  Future<KeystoreStatus> status();
}

/// Wraps a vault and counts every change to it. Readers that remember keys compare [tick] to know when to look again.
class TickVault implements E2eeVault {
  TickVault(this.inner);
  final E2eeVault inner;

  /// Process-wide: bumped by any write or delete on any [TickVault].
  static int tick = 0;

  @override
  Future<Uint8List?> read(String name) => inner.read(name);
  @override
  Future<void> write(String name, Uint8List value) async {
    tick++;
    await inner.write(name, value);
    tick++;
  }

  @override
  Future<void> delete(String name) async {
    tick++;
    await inner.delete(name);
    tick++;
  }

  @override
  Future<List<String>> names() => inner.names();
  @override
  Future<KeystoreStatus> status() => inner.status();
}

/// In-memory vault for tests and hosts. Like [SecureVault], deleting key
/// material ([isVaultKeyMaterial]) archives it instead of destroying it.
class MemoryVault implements E2eeVault, VaultArchive {
  final Map<String, Uint8List> data = <String, Uint8List>{};

  /// Archived sets by id: name -> value.
  final Map<String, Map<String, Uint8List>> archived = <String, Map<String, Uint8List>>{};
  int _archiveSeq = 0;

  @override
  Future<Uint8List?> read(String name) async => data[name];
  @override
  Future<void> write(String name, Uint8List value) async => data[name] = Uint8List.fromList(value);
  @override
  Future<void> delete(String name) => archiveNames(<String>[name]);

  @override
  Future<void> archiveNames(List<String> names) async {
    final Map<String, Uint8List> set = <String, Uint8List>{};
    for (final String n in names) {
      final Uint8List? v = data.remove(n);
      if (v != null && isVaultKeyMaterial(n)) set[n] = v;
    }
    if (set.isNotEmpty) archived['${++_archiveSeq}'] = set;
  }

  @override
  Future<List<VaultArchiveSet>> archives() async {
    final List<String> ids = archived.keys.toList()..sort((String a, String b) => int.parse(b).compareTo(int.parse(a)));
    return <VaultArchiveSet>[for (final String id in ids) VaultArchiveSet(id, archived[id]!.keys.toList())];
  }

  @override
  Future<Uint8List?> readArchived(String id, String name) async => archived[id]?[name];
  @override
  Future<List<String>> names() async => data.keys.toList();
  @override
  Future<KeystoreStatus> status() async => const KeystoreStatus(level: KeystoreLevel.software);
}

/// Thin wrapper over the native key-store channel, which has the same name and
/// contract on both platforms (`encrypt`, `decrypt`, `status`, `recreateKey`,
/// `setSecure`):
///  * Android (packages/e2ee_keystore, E2eeKeystorePlugin.kt, registered in every engine): ONE non-extractable AES-256-GCM key in the
///    Android Keystore (StrongBox / TEE).
///  * iOS (SecureKeyChannel.swift): ONE non-extractable P-256 key (Secure
///    Enclave when present) used for ECIES, so secrets are encrypted with the
///    public half and only decrypted with the hardware key.
/// Either way Ed25519, X25519 and XChaCha20 are NOT hardware-backed: they run
/// in app memory, and only the key that protects them at rest is.
class KeystoreChannel {
  const KeystoreChannel({MethodChannel? channel}) : _override = channel;
  final MethodChannel? _override;
  static const MethodChannel _default = MethodChannel('app.openfamily/keystore');
  MethodChannel get _ch => _override ?? _default;

  Future<Uint8List> encrypt(Uint8List plain) async {
    final Uint8List? r = await _ch.invokeMethod<Uint8List>('encrypt', plain);
    if (r == null) throw PlatformException(code: 'null');
    return r;
  }

  Future<Uint8List> decrypt(Uint8List blob) async {
    try {
      final Uint8List? r = await _ch.invokeMethod<Uint8List>('decrypt', blob);
      if (r == null) throw PlatformException(code: 'null');
      return r;
    } on PlatformException catch (e) {
      if (e.code == 'invalidated') throw const VaultInvalidatedException();
      if (e.code == 'locked') throw const VaultLockedException();
      rethrow;
    }
  }

  /// Decrypts a blob written under the pre-0.24.2 Android key. Throws [VaultLockedException] while the phone is locked.
  Future<Uint8List> decryptLegacy(Uint8List blob) async {
    try {
      final Uint8List? r = await _ch.invokeMethod<Uint8List>('decryptLegacy', blob);
      if (r == null) throw PlatformException(code: 'null');
      return r;
    } on PlatformException catch (e) {
      if (e.code == 'invalidated') throw const VaultInvalidatedException();
      if (e.code == 'locked') throw const VaultLockedException();
      rethrow;
    }
  }

  /// Removes the legacy key. Call only after every blob was re-wrapped and read back.
  Future<void> deleteLegacy() => _ch.invokeMethod<void>('deleteLegacy');

  Future<KeystoreStatus> status() async {
    try {
      final Map<dynamic, dynamic>? m = await _ch.invokeMethod<Map<dynamic, dynamic>>('status');
      if (m == null) return const KeystoreStatus(level: KeystoreLevel.unavailable);
      final String l = (m['level'] as String?) ?? 'unavailable';
      return KeystoreStatus(
        level: switch (l) {
          'strongbox' => KeystoreLevel.strongBox,
          'tee' => KeystoreLevel.tee,
          'secure_enclave' => KeystoreLevel.secureEnclave,
          'keychain' => KeystoreLevel.keychain,
          'software' => KeystoreLevel.software,
          _ => KeystoreLevel.unavailable,
        },
        unlockedDeviceRequired: m['unlockedDeviceRequired'] == true,
        userAuthRequired: m['userAuthRequired'] == true,
        legacyKey: m['legacyKey'] == true,
      );
    } on MissingPluginException {
      return const KeystoreStatus(level: KeystoreLevel.unavailable);
    } on PlatformException {
      return const KeystoreStatus(level: KeystoreLevel.unavailable);
    }
  }

  /// Recreates the wrapping key, optionally bound to the device credential or
  /// biometrics (valid for a short window after authenticating). All stored
  /// secrets must be re-encrypted by the caller afterwards.
  Future<void> recreateKey({required bool requireUserAuth}) =>
      _ch.invokeMethod<void>('recreateKey', <String, dynamic>{'requireUserAuth': requireUserAuth});
}

/// A stored value (or the store itself) could not be read even after bounded
/// retries. This is NOT "no data": callers must never treat it as missing and
/// must never generate a new identity because of it. Try again later; the
/// stored copy is kept untouched.
class VaultUnreadableException implements Exception {
  const VaultUnreadableException(this.stage, [this.cause = '']);

  /// `storage` (the secure-storage plugin failed), `decrypt` (the Keystore did
  /// not open the blob), `format` (the stored text is not a blob) or `verify`.
  final String stage;

  /// Type name of the underlying failure (never key material).
  final String cause;

  @override
  String toString() => 'VaultUnreadableException($stage${cause.isEmpty ? '' : ', $cause'})';
}

/// One set of key blobs that was put aside instead of deleted (by "Set this
/// phone up again", a different account signing in, or an overwrite).
class VaultArchiveSet {
  const VaultArchiveSet(this.id, this.names);

  /// Milliseconds since epoch when it was put aside; newest has the largest id.
  final String id;
  final List<String> names;
}

/// Optional vault capability: removed key material is kept aside (still
/// wrapped by the Keystore key) so a mistaken reset can be undone.
abstract class VaultArchive {
  /// Puts [names] aside as ONE archived set and removes them from the live
  /// vault. Names that are not key material are simply deleted.
  Future<void> archiveNames(List<String> names);

  /// Archived sets, newest first.
  Future<List<VaultArchiveSet>> archives();

  /// Decrypts one archived value, or null when it is not there.
  Future<Uint8List?> readArchived(String id, String name);
}

/// Names that hold key material (identity, device id, circle and server line
/// keys). Only these are mirrored, retried, write-verified and archived; the
/// offline cache, queue and last positions are ordinary data.
bool isVaultKeyMaterial(String name) =>
    name == 'identity_seed' ||
    name == 'device_id' ||
    name == 'identity_user' ||
    name.startsWith('ck/') ||
    name.startsWith('sk/');

/// A plain app-private copy of the Keystore-WRAPPED vault blobs (flag byte 1
/// or 2 only; a plain flag-0 blob is never mirrored). The blobs are already
/// AES-256-GCM encrypted by the non-extractable Keystore key, so this copy is
/// as useless to anyone without the phone's Keystore as the primary one. It
/// exists because flutter_secure_storage silently reads EncryptedSharedPreferences
/// as EMPTY for the rest of the process when the Tink keyset cannot be opened
/// once (see docs/design/E2EE.md, "Keys survive updates").
abstract class VaultMirror {
  Future<String?> get(String key, {bool fresh = false});
  Future<void> set(String key, String value);
  Future<void> remove(String key);
  Future<List<String>> keys({bool fresh = false});
}

class MemoryVaultMirror implements VaultMirror {
  final Map<String, String> data = <String, String>{};
  bool failAll = false;

  void _check() {
    if (failAll) throw StateError('mirror unavailable');
  }

  @override
  Future<String?> get(String key, {bool fresh = false}) async {
    _check();
    return data[key];
  }

  @override
  Future<void> set(String key, String value) async {
    _check();
    data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _check();
    data.remove(key);
  }

  @override
  Future<List<String>> keys({bool fresh = false}) async {
    _check();
    return data.keys.toList();
  }
}

/// [VaultMirror] in the app's ordinary SharedPreferences (app-private, never
/// backed up: allowBackup=false). Survives exactly the failures that make the
/// Keystore-backed preferences unreadable.
class PrefsVaultMirror implements VaultMirror {
  const PrefsVaultMirror();
  static const String prefix = 'e2ee_vault_mirror/';

  Future<SharedPreferences> _prefs(bool fresh) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    // The background engine writes too: re-read the file when it matters.
    if (fresh) await p.reload();
    return p;
  }

  @override
  Future<String?> get(String key, {bool fresh = false}) async => (await _prefs(fresh)).getString('$prefix$key');

  @override
  Future<void> set(String key, String value) async {
    await (await _prefs(false)).setString('$prefix$key', value);
  }

  @override
  Future<void> remove(String key) async {
    await (await _prefs(false)).remove('$prefix$key');
  }

  @override
  Future<List<String>> keys({bool fresh = false}) async => (await _prefs(fresh))
      .getKeys()
      .where((String k) => k.startsWith(prefix))
      .map((String k) => k.substring(prefix.length))
      .toList();
}

/// Production vault: AES-256-GCM (Keystore key) over the secret, stored in
/// flutter_secure_storage. Without the native channel (non-Android, tests on a
/// host) it falls back to flutter_secure_storage alone and reports that.
///
/// Survival rules for key material ([isVaultKeyMaterial]), see
/// docs/design/E2EE.md "Keys survive updates":
///  * a read failure is retried a few times and then raised as
///    [VaultUnreadableException]; it is never reported as "no key";
///  * every wrapped blob also lives in a [VaultMirror]; when the primary store
///    is empty or failing, the mirror copy is used (and the primary healed);
///  * writes are write-verify-swap: the previous blob is kept until the new one
///    reads back and decrypts to the same bytes;
///  * delete never destroys key material: it is archived (still wrapped).
/// Every failure, fallback, heal and archive is recorded in [StorageEventLog].
class SecureVault implements E2eeVault, VaultArchive {
  SecureVault({
    FlutterSecureStorage? storage,
    KeystoreChannel channel = const KeystoreChannel(),
    VaultMirror? mirror,
    bool? useMirror,
    List<Duration>? retryDelays,
  })  : _storage = storage ?? defaultStorage,
        _channel = channel,
        _mirror = mirror ?? ((useMirror ?? _mirrorByDefault) ? const PrefsVaultMirror() : null),
        _delays = retryDelays ?? const <Duration>[Duration(milliseconds: 120), Duration(milliseconds: 400)];

  /// Android only: iOS Keychain items do not have the EncryptedSharedPreferences
  /// failure mode, and NSUserDefaults is part of iCloud backups.
  static bool get _mirrorByDefault => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The vault's secure-storage options. `resetOnError: false` is spelled out:
  /// the plugin must never wipe the file on a read error (see docs/design/E2EE.md).
  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false,
      sharedPreferencesName: 'openfamily_e2ee',
      preferencesKeyPrefix: 'e2ee_',
    ),
    // iOS: a dedicated Keychain namespace (so names()/readAll never
    // lists tokens), readable after the first unlock so the
    // background isolate can seal location while the phone is locked,
    // this device only (no backup migration) and never iCloud-synced.
    iOptions: iosVaultOptions,
  );

  /// Keychain options of the vault blobs on iOS. See docs/design/E2EE.md.
  static const IOSOptions iosVaultOptions = IOSOptions(
    accountName: 'openfamily_e2ee',
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  /// How many archived sets are kept (oldest dropped beyond this).
  static const int maxArchives = 5;

  final FlutterSecureStorage _storage;
  final KeystoreChannel _channel;
  final VaultMirror? _mirror;
  final List<Duration> _delays;
  bool _native = false;

  static void _log(String code, [String detail = '']) =>
      StorageEventLog.instance.record(code, store: 'vault', detail: detail);

  Future<bool> _hasNative() async {
    // Only a positive answer is remembered: one failed status call must not
    // make every later write store plaintext.
    if (_native) return true;
    return _native = (await _channel.status()).level != KeystoreLevel.unavailable;
  }

  static bool _isWrapped(String raw) {
    try {
      final Uint8List b = base64.decode(raw);
      return b.isNotEmpty && (b[0] == 1 || b[0] == 2);
    } on FormatException {
      return false;
    }
  }

  // ---- mirror helpers: best effort, never throw ----------------------------

  Future<String?> _mGet(String key, {bool fresh = false}) async {
    final VaultMirror? m = _mirror;
    if (m == null) return null;
    try {
      return await m.get(key, fresh: fresh);
    } catch (e) {
      _log('mirror_error', 'get ${e.runtimeType}');
      return null;
    }
  }

  Future<bool> _mSet(String key, String value) async {
    final VaultMirror? m = _mirror;
    if (m == null) return false;
    try {
      await m.set(key, value);
      return await m.get(key) == value;
    } catch (e) {
      _log('mirror_error', 'set ${e.runtimeType}');
      return false;
    }
  }

  Future<void> _mRemove(String key) async {
    final VaultMirror? m = _mirror;
    if (m == null) return;
    try {
      await m.remove(key);
    } catch (e) {
      _log('mirror_error', 'remove ${e.runtimeType}');
    }
  }

  Future<List<String>> _mKeys({bool fresh = false}) async {
    final VaultMirror? m = _mirror;
    if (m == null) return <String>[];
    try {
      return await m.keys(fresh: fresh);
    } catch (e) {
      _log('mirror_error', 'keys ${e.runtimeType}');
      return <String>[];
    }
  }

  // ---- blob format ---------------------------------------------------------

  /// Opens one stored blob. First byte: 2 = wrapped with the current key (usable with the phone locked), 1 = wrapped
  /// by an older app version (Android: the unlocked-device-only key, until migrateLegacy re-wraps it; iOS: the same
  /// key), 0 = plain (fallback platforms). Empty means nothing stored.
  Future<Uint8List?> _open(String raw) async {
    final Uint8List stored;
    try {
      stored = base64.decode(raw);
    } on FormatException {
      throw const VaultUnreadableException('format', 'FormatException');
    }
    if (stored.isEmpty) return null;
    final Uint8List body = Uint8List.sublistView(stored, 1);
    if (stored[0] == 2) return _channel.decrypt(body);
    if (stored[0] == 1) {
      final bool legacy = (await _channel.status()).legacyKey;
      try {
        return legacy ? await _channel.decryptLegacy(body) : await _channel.decrypt(body);
      } on VaultLockedException {
        rethrow;
      } catch (first) {
        if (legacy) rethrow;
        // The status call may have failed (it then reports "no legacy key"): try the old key once, but report
        // the first failure if that does not open it either.
        try {
          return await _channel.decryptLegacy(body);
        } catch (_) {
          throw first;
        }
      }
    }
    return body;
  }

  /// [_open] with bounded retries for transient Keystore errors. A locked key is
  /// not retried (it is fine, just not usable now); format errors are final.
  Future<Uint8List?> _openRetrying(String name, String raw) async {
    Object? last;
    for (int i = 0; i <= _delays.length; i++) {
      try {
        return await _open(raw);
      } on VaultLockedException {
        rethrow;
      } on VaultUnreadableException {
        rethrow;
      } catch (e) {
        last = e;
        _log('decrypt_error', '${_tag(name)} ${e.runtimeType} try=$i');
        // An "invalidated" answer is retried once, other errors up to the limit.
        if (e is VaultInvalidatedException && i >= 1) break;
        if (i < _delays.length) await Future<void>.delayed(_delays[i]);
      }
    }
    if (last is VaultInvalidatedException) throw last;
    throw VaultUnreadableException('decrypt', last.runtimeType.toString());
  }

  /// Short non-secret label for logs: the kind of name, never a circle id.
  static String _tag(String name) {
    final int slash = name.indexOf('/');
    return slash < 0 ? name : name.substring(0, slash);
  }

  // ---- E2eeVault -----------------------------------------------------------

  @override
  Future<Uint8List?> read(String name) async {
    if (!isVaultKeyMaterial(name)) {
      final String? raw = await _storage.read(key: name);
      return raw == null ? null : _open(raw);
    }
    String? raw;
    Object? storeErr;
    for (int i = 0; i <= _delays.length; i++) {
      try {
        raw = await _storage.read(key: name);
        storeErr = null;
        break;
      } catch (e) {
        storeErr = e;
        _log('read_error', '${_tag(name)} ${e.runtimeType} try=$i');
        if (i < _delays.length) await Future<void>.delayed(_delays[i]);
      }
    }
    if (raw != null && raw.isNotEmpty) {
      try {
        final Uint8List? v = await _openRetrying(name, raw);
        if (_isWrapped(raw) && await _mGet('live/$name') != raw) {
          // Backfill: blobs written before the mirror existed (or by the other engine).
          if (await _mSet('live/$name', raw)) _log('mirror_backfill', _tag(name));
        }
        return v;
      } on VaultLockedException {
        rethrow;
      } catch (e) {
        final String? m = await _mGet('live/$name', fresh: true);
        if (m != null && m != raw) {
          try {
            final Uint8List? v = await _openRetrying(name, m);
            _log('mirror_hit', '${_tag(name)} primary=undecryptable');
            return v;
          } catch (_) {}
        }
        _log('read_failed', '${_tag(name)} ${e is VaultUnreadableException ? e.stage : e.runtimeType}');
        rethrow;
      }
    }
    // The primary store is empty or failing: the mirror copy, if any.
    final String? m = await _mGet('live/$name', fresh: true);
    if (m != null) {
      final Uint8List? v = await _openRetrying(name, m);
      _log('mirror_hit', '${_tag(name)} primary=${storeErr == null ? 'empty' : 'error'}');
      if (storeErr == null) {
        try {
          await _storage.write(key: name, value: m);
          _log('primary_healed', _tag(name));
        } catch (e) {
          _log('heal_error', '${_tag(name)} ${e.runtimeType}');
        }
      }
      return v;
    }
    if (storeErr != null) {
      _log('read_failed', '${_tag(name)} storage ${storeErr.runtimeType}');
      throw VaultUnreadableException('storage', storeErr.runtimeType.toString());
    }
    return null;
  }

  @override
  Future<void> write(String name, Uint8List value) async {
    final bool native = await _hasNative();
    if (!native && _mirror != null && isVaultKeyMaterial(name)) {
      // Android always has the Keystore plugin: "unavailable" here is a failed status call, not a platform
      // without one. Never store key material unwrapped because of a hiccup; the caller retries later.
      _log('write_error', '${_tag(name)} keystore unavailable');
      throw const VaultUnreadableException('keystore', 'status unavailable');
    }
    final Uint8List body = native ? await _channel.encrypt(value) : value;
    final String s = base64.encode(<int>[native ? 2 : 0, ...body]);
    if (!isVaultKeyMaterial(name)) {
      await _storage.write(key: name, value: s);
      return;
    }
    // Write-verify-swap. 1) the new blob must open to the same bytes before it replaces anything.
    bool opens = false;
    try {
      final Uint8List? back = await _open(s);
      opens = back != null && listEquals(back, value);
    } catch (_) {}
    if (!opens) {
      _log('write_verify_failed', '${_tag(name)} new blob does not open');
      throw const VaultUnreadableException('verify', 'new blob does not open');
    }
    // 2) keep the previous blob aside until the new one is stored and read back.
    String? prev;
    try {
      prev = await _storage.read(key: name);
    } catch (_) {}
    prev ??= await _mGet('live/$name');
    final bool keepPrev = prev != null && prev != s && _isWrapped(prev);
    if (keepPrev) await _mSet('prev/$name', prev);
    bool primaryOk = false;
    for (int attempt = 0; attempt < 2 && !primaryOk; attempt++) {
      try {
        await _storage.write(key: name, value: s);
        primaryOk = await _storage.read(key: name) == s;
        if (!primaryOk) _log('readback_mismatch', '${_tag(name)} attempt=$attempt');
      } catch (e) {
        _log('write_error', '${_tag(name)} ${e.runtimeType} attempt=$attempt');
      }
    }
    final bool mirrorOk = native && await _mSet('live/$name', s);
    if (!primaryOk && !mirrorOk) {
      // Nothing holds the new blob: put the old one back where it was.
      if (prev != null) {
        try {
          await _storage.write(key: name, value: prev);
        } catch (_) {}
      }
      _log('write_failed', _tag(name));
      throw StateError('Could not save a key on this phone.');
    }
    // 3) swap: the new blob is verified, the previous copy is no longer needed.
    if (keepPrev) await _mRemove('prev/$name');
  }

  /// Ordinary data is deleted. Key material is never destroyed here: it is
  /// archived (still wrapped) and removed from the live stores.
  @override
  Future<void> delete(String name) async {
    if (isVaultKeyMaterial(name)) {
      await archiveNames(<String>[name]);
      return;
    }
    await _storage.delete(key: name);
  }

  /// Puts [names] aside as one archived set (newest kept, oldest beyond
  /// [maxArchives] dropped) and removes them from the live stores. Without a
  /// mirror (iOS) or for an unwrapped blob it simply deletes, as before.
  @override
  Future<void> archiveNames(List<String> names) async {
    final String id = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
    int kept = 0;
    for (final String name in names) {
      String? raw;
      try {
        raw = await _storage.read(key: name);
      } catch (_) {}
      raw ??= await _mGet('live/$name', fresh: true);
      if (raw != null && _isWrapped(raw) && isVaultKeyMaterial(name) && await _mSet('archive/$id/$name', raw)) kept++;
      try {
        await _storage.delete(key: name);
      } catch (e) {
        _log('delete_error', '${_tag(name)} ${e.runtimeType}');
      }
      await _mRemove('live/$name');
      await _mRemove('prev/$name');
    }
    _log('archive', 'names=${names.length} kept=$kept');
    await _pruneArchives();
  }

  Future<void> _pruneArchives() async {
    final List<VaultArchiveSet> sets = await archives();
    if (sets.length <= maxArchives) return;
    for (final VaultArchiveSet old in sets.sublist(maxArchives)) {
      for (final String n in old.names) {
        await _mRemove('archive/${old.id}/$n');
      }
      _log('archive_pruned', 'set=${old.id}');
    }
  }

  @override
  Future<List<VaultArchiveSet>> archives() async {
    final Map<String, List<String>> byId = <String, List<String>>{};
    for (final String k in await _mKeys(fresh: true)) {
      if (!k.startsWith('archive/')) continue;
      final String rest = k.substring('archive/'.length);
      final int slash = rest.indexOf('/');
      if (slash <= 0) continue;
      byId.putIfAbsent(rest.substring(0, slash), () => <String>[]).add(rest.substring(slash + 1));
    }
    final List<String> ids = byId.keys.toList()
      ..sort((String a, String b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0));
    return <VaultArchiveSet>[for (final String id in ids) VaultArchiveSet(id, byId[id]!)];
  }

  @override
  Future<Uint8List?> readArchived(String id, String name) async {
    final String? raw = await _mGet('archive/$id/$name', fresh: true);
    return raw == null ? null : _openRetrying(name, raw);
  }

  /// Every live name (the primary store and the mirror together). When the
  /// primary store fails, the mirror's names are used (and the failure logged).
  @override
  Future<List<String>> names() async {
    final Set<String> out = <String>{};
    Object? err;
    try {
      out.addAll((await _storage.readAll()).keys);
    } catch (e) {
      err = e;
      _log('readall_error', '${e.runtimeType}');
    }
    final List<String> mirrored = <String>[
      for (final String k in await _mKeys(fresh: err != null))
        if (k.startsWith('live/')) k.substring('live/'.length),
    ];
    if (err != null && mirrored.isEmpty) throw VaultUnreadableException('storage', err.runtimeType.toString());
    out.addAll(mirrored);
    return out.toList();
  }

  /// Re-wraps every blob that an older version wrapped with the unlocked-device-only Android key under the current
  /// key, so sealing works with the screen locked. Safe by construction: each blob is written, read back and compared
  /// before the next one; nothing is deleted on any doubt; the old key is removed only when no old blob remains.
  /// Never touches identity material in any other way, never creates a new identity. Run it in the foreground
  /// (the old key cannot be used while locked: [VaultMigration.waitingForUnlock], try again later).
  Future<VaultMigration> migrateLegacy() async {
    final KeystoreStatus st = await _channel.status();
    if (!st.legacyKey) return VaultMigration.notNeeded;
    try {
      final Map<String, String> all = await _storage.readAll();
      for (final MapEntry<String, String> e in all.entries) {
        final Uint8List stored = base64.decode(e.value);
        if (stored.isEmpty || stored[0] != 1) continue;
        final Uint8List plain = await _channel.decryptLegacy(Uint8List.sublistView(stored, 1));
        final Uint8List wrapped = await _channel.encrypt(plain);
        final String next = base64.encode(<int>[2, ...wrapped]);
        // The old blob stays in the mirror until the new one is verified.
        if (isVaultKeyMaterial(e.key)) await _mSet('prev/${e.key}', e.value);
        await _storage.write(key: e.key, value: next);
        // Read back through the normal path; restore the old blob if it does not match.
        bool same = false;
        try {
          final String? raw = await _storage.read(key: e.key);
          final Uint8List? back = raw == null ? null : await _open(raw);
          same = raw == next && back != null && listEquals(back, plain);
        } catch (_) {}
        if (!same) {
          await _storage.write(key: e.key, value: e.value);
          _log('migration', 'v1->v2 failedKept ${_tag(e.key)}');
          return VaultMigration.failedKept;
        }
        if (isVaultKeyMaterial(e.key)) {
          await _mSet('live/${e.key}', next);
          await _mRemove('prev/${e.key}');
        }
      }
      final Map<String, String> after = await _storage.readAll();
      final bool anyOld = after.values.any((String v) {
        final Uint8List b = base64.decode(v);
        return b.isNotEmpty && b[0] == 1;
      });
      if (anyOld) {
        _log('migration', 'v1->v2 failedKept old blobs remain');
        return VaultMigration.failedKept;
      }
      await _channel.deleteLegacy();
      _log('migration', 'v1->v2 done');
      return VaultMigration.done;
    } on VaultLockedException {
      return VaultMigration.waitingForUnlock;
    } catch (e) {
      // Invalidated legacy key or a platform error: keep every blob exactly as it was. The normal read path
      // reports the invalidation and the app asks for the recovery phrase; nothing is regenerated here.
      _log('migration', 'v1->v2 failedKept ${e.runtimeType}');
      return VaultMigration.failedKept;
    }
  }

  @override
  Future<KeystoreStatus> status() => _channel.status();
}

/// Blocks screenshots / recents thumbnails while a secret is on screen
/// (Android FLAG_SECURE; on iOS the native side hides the window while the
/// screen is being recorded/mirrored and in the app switcher). Best effort on
/// other platforms.
class ScreenSecurity {
  const ScreenSecurity({MethodChannel? channel}) : _override = channel;
  final MethodChannel? _override;
  static const MethodChannel _default = MethodChannel('app.openfamily/keystore');
  MethodChannel get _ch => _override ?? _default;
  Future<void> setSecure(bool on) async {
    try {
      await _ch.invokeMethod<void>('setSecure', on);
    } on MissingPluginException {
      // No native implementation on this platform: nothing to do.
    } on PlatformException {
      // Ignore: the phrase screen still warns the user.
    }
  }
}
