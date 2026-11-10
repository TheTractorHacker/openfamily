import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage_event_log.dart';
import 'e2ee_crypto.dart';

/// "Keep this phone's key safe through reinstalls" (docs/design/E2EE.md,
/// "Keys survive a reinstall").
///
/// A copy of the minimum needed to recreate this phone's identity (the 32-byte
/// seed, the device id and the owning account id) is kept in a place that the
/// operating system does NOT delete with the app:
///  * Android: Google Play services Block Store. It survives uninstall and
///    reinstall on the same phone when Google backup is on. It is also backed
///    up to the user's Google account, and so reaches a phone restored from that
///    backup, ONLY when Google can end-to-end encrypt it (screen lock set,
///    Android 9+; decided in KeyBackupChannel.kt). Otherwise it stays local.
///    Generic Android Auto Backup of vault files stays off.
///  * iOS: one Keychain item (`openfamily_key_backup`, AfterFirstUnlock, NOT
///    ThisDeviceOnly, never synchronised through iCloud Keychain). Keychain items
///    outlive the app, and an encrypted device backup carries a non-ThisDeviceOnly
///    item to a restored iPhone. Not iCloud Keychain sync: that would put one
///    device id on every Apple device of the user.
///
/// The blob is authenticated with XChaCha20-Poly1305 (version byte, account id
/// as associated data) under a key derived from public constants and the account
/// id. That is NOT a secret: the real protection is the platform store (Google's
/// end-to-end encryption, the iOS keychain) and, above all, the server check in
/// E2eeService. The seed is used only when the signed-in account owns the copy,
/// and the server still lists that device id as active with exactly the public
/// keys the seed derives. A reset or revoked key is therefore never resurrected.
/// No phone binding is added on purpose: it would stop a restored new phone from
/// opening the copy, which is the point of the feature.
///
/// SECURITY: nothing here logs or returns key material, blobs or ids; the
/// event log only gets reason codes.
abstract class PlatformKeyStore {
  /// The stored bytes for [key], or null when there are none. May throw.
  Future<Uint8List?> read(String key);

  /// May throw.
  Future<void> write(String key, Uint8List value);

  /// May throw.
  Future<void> delete(String key);

  /// Removes every copy this app keeps here. May throw.
  Future<void> deleteAll();

  /// A per-phone value mixed into the seal key; '' on both platforms (see the
  /// class comment: no phone binding). May throw.
  Future<String> phoneSecret();

  /// Short platform label for logs ("blockstore", "keychain", "memory").
  String get name;
}

/// Android: the `app.openfamily/key_backup` channel (KeyBackupChannel.kt).
class BlockStoreKeyStore implements PlatformKeyStore {
  const BlockStoreKeyStore({MethodChannel? channel}) : _override = channel;
  final MethodChannel? _override;
  static const MethodChannel _default = MethodChannel('app.openfamily/key_backup');
  MethodChannel get _ch => _override ?? _default;

  @override
  String get name => 'blockstore';

  @override
  Future<Uint8List?> read(String key) => _ch.invokeMethod<Uint8List>('retrieve', <String, dynamic>{'key': key});

  @override
  Future<void> write(String key, Uint8List value) async {
    final bool? ok = await _ch.invokeMethod<bool>('store', <String, dynamic>{'key': key, 'bytes': value});
    if (ok != true) throw PlatformException(code: 'not_stored');
  }

  @override
  Future<void> delete(String key) => _ch.invokeMethod<void>('delete', <String, dynamic>{'key': key});

  @override
  Future<void> deleteAll() => _ch.invokeMethod<void>('deleteAll');

  @override
  Future<String> phoneSecret() async => '';
}

/// iOS: a Keychain item in its own service, which the fresh-install wipe in
/// SecureKeyChannel.swift does not touch (it wipes only the vault services).
class KeychainKeyStore implements PlatformKeyStore {
  const KeychainKeyStore({FlutterSecureStorage? storage}) : _storage = storage ?? defaultStorage;
  final FlutterSecureStorage _storage;

  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'openfamily_key_backup',
      accessibility: KeychainAccessibility.first_unlock,
      synchronizable: false,
    ),
  );

  @override
  String get name => 'keychain';

  @override
  Future<Uint8List?> read(String key) async {
    final String? v = await _storage.read(key: key);
    return v == null ? null : Uint8List.fromList(base64.decode(v));
  }

  @override
  Future<void> write(String key, Uint8List value) => _storage.write(key: key, value: base64.encode(value));

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();

  @override
  Future<String> phoneSecret() async => '';
}

/// In-memory store for tests.
class MemoryPlatformKeyStore implements PlatformKeyStore {
  MemoryPlatformKeyStore({this.secret = 'phone-1'});
  final Map<String, Uint8List> data = <String, Uint8List>{};
  String secret;
  bool failAll = false;

  /// The error code [failAll] fails with: 'unavailable' is "no store on this phone" (as without Google Play
  /// services); any other code is a failing store (a timeout, a Play services error).
  String failCode = 'unavailable';
  int writes = 0;

  void _check() {
    if (failAll) throw PlatformException(code: failCode);
  }

  @override
  String get name => 'memory';

  @override
  Future<Uint8List?> read(String key) async {
    _check();
    return data[key];
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    _check();
    writes++;
    data[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String key) async {
    _check();
    data.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _check();
    data.clear();
  }

  @override
  Future<String> phoneSecret() async {
    _check();
    return secret;
  }
}

/// The on/off switch (default ON). Kept in ordinary app preferences: a
/// reinstall resets it to ON, which is fine because turning it off deleted
/// the copy, so there is nothing to bring back.
abstract class KeyBackupPrefs {
  Future<bool> enabled();
  Future<void> setEnabled(bool on);

  /// Entries whose removal from the platform store failed (entry names, or [KeyBackup.allEntries]). They are
  /// tried again before a copy is read or saved, so an erased key cannot come back by itself.
  Future<Set<String>> pendingRemovals();
  Future<void> setPendingRemovals(Set<String> names);
}

class SharedKeyBackupPrefs implements KeyBackupPrefs {
  const SharedKeyBackupPrefs();
  static const String key = 'e2ee_key_backup_on';
  static const String pendingKey = 'e2ee_key_backup_pending';

  @override
  Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(key) ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> setEnabled(bool on) async {
    if (!await (await SharedPreferences.getInstance()).setBool(key, on)) throw StateError('prefs');
  }

  @override
  Future<Set<String>> pendingRemovals() async =>
      ((await SharedPreferences.getInstance()).getStringList(pendingKey) ?? const <String>[]).toSet();

  @override
  Future<void> setPendingRemovals(Set<String> names) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (names.isEmpty) {
      await p.remove(pendingKey);
    } else {
      await p.setStringList(pendingKey, names.toList());
    }
  }
}

class MemoryKeyBackupPrefs implements KeyBackupPrefs {
  bool on = true;
  bool failWrites = false;
  Set<String> pending = <String>{};
  @override
  Future<bool> enabled() async => on;
  @override
  Future<void> setEnabled(bool v) async {
    if (failWrites) throw StateError('prefs');
    on = v;
  }

  @override
  Future<Set<String>> pendingRemovals() async => <String>{...pending};
  @override
  Future<void> setPendingRemovals(Set<String> names) async => pending = <String>{...names};
}

/// What a stored copy holds once opened.
class BackedUpIdentity {
  const BackedUpIdentity(this.userId, this.deviceId, this.seed);
  final String userId;
  final String deviceId;
  final Uint8List seed;
}

/// Why [KeyBackup.load] found nothing usable (reason codes for the event log).
///  * [unavailable]: this phone has no such store (no Google Play services): there can be no copy.
///  * [storeError]: the store exists but could not be read (a timeout, a Play services error): a copy MAY exist, so
///    nothing may be created over it.
enum KeyBackupMiss { off, none, unavailable, storeError, otherPhoneOrDamaged, otherAccount }

/// Seals, stores, opens and removes the platform copy. Every method is best
/// effort: failures are recorded and swallowed, never thrown into sign-in.
class KeyBackup {
  KeyBackup({required this.store, KeyBackupPrefs? prefs, this.timeout = const Duration(seconds: 8)})
      : prefs = prefs ?? const SharedKeyBackupPrefs();

  final PlatformKeyStore store;
  final KeyBackupPrefs prefs;
  final Duration timeout;

  static const int version = 1;

  /// The pending-removal marker for "every entry" (a removal for an owner that could not be named).
  static const String allEntries = '*';
  static const String _domain = 'orbitly-keybackup-v1';
  static final Xchacha20 _aead = Xchacha20.poly1305Aead();

  /// The last miss of [load] (diagnostics and tests).
  KeyBackupMiss? lastMiss;

  /// The platform store for this phone, or null where there is none.
  static PlatformKeyStore? platformStore() {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return const BlockStoreKeyStore();
      case TargetPlatform.iOS:
        return const KeychainKeyStore();
      default:
        return null;
    }
  }

  static void _log(String code, [String detail = '']) =>
      StorageEventLog.instance.record(code, store: 'keybackup', detail: detail);

  /// The entry name for an account: a hash, so the store never lists account ids.
  static Future<String> entryKey(String userId) async =>
      'orbitly_e2ee_${E2ee.hex(await E2ee.sha256(utf8.encode('$_domain\x00$userId'))).substring(0, 32)}';

  static Future<SecretKey> _key(String phoneSecret, String userId) async => SecretKey(
      await E2ee.hkdf(utf8.encode(phoneSecret), utf8.encode(_domain), utf8.encode('seal\x00$userId'), 32));

  static Uint8List _aad(String userId) => Uint8List.fromList(utf8.encode('$_domain\x00$userId'));

  /// version(1) || nonce(24) || ciphertext || mac(16), over
  /// seed(32) || len(1) || deviceId || len(1) || userId.
  static Future<Uint8List> seal(BackedUpIdentity id, String phoneSecret) async {
    if (id.seed.length != 32) throw ArgumentError('seed');
    final List<int> d = utf8.encode(id.deviceId), u = utf8.encode(id.userId);
    if (d.isEmpty || d.length > 255 || u.isEmpty || u.length > 255) throw ArgumentError('ids');
    final Uint8List plain = Uint8List.fromList(<int>[...id.seed, d.length, ...d, u.length, ...u]);
    final Uint8List nonce = E2ee.randomBytes(24);
    final SecretBox box =
        await _aead.encrypt(plain, secretKey: await _key(phoneSecret, id.userId), nonce: nonce, aad: _aad(id.userId));
    return Uint8List.fromList(<int>[version, ...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Opens a blob for [userId]; null when it does not open (another phone,
  /// another account, damaged, unknown version).
  static Future<BackedUpIdentity?> open(Uint8List blob, String phoneSecret, String userId) async {
    if (blob.length < 1 + 24 + 16 + 32 + 2 || blob[0] != version) return null;
    final Uint8List nonce = Uint8List.sublistView(blob, 1, 25);
    final Uint8List ct = Uint8List.sublistView(blob, 25, blob.length - 16);
    final Uint8List mac = Uint8List.sublistView(blob, blob.length - 16);
    final List<int> plain;
    try {
      plain = await _aead.decrypt(SecretBox(ct, nonce: nonce, mac: Mac(mac)),
          secretKey: await _key(phoneSecret, userId), aad: _aad(userId));
    } on SecretBoxAuthenticationError {
      return null;
    }
    try {
      final Uint8List seed = Uint8List.fromList(plain.sublist(0, 32));
      int i = 32;
      final int dl = plain[i++];
      final String deviceId = utf8.decode(plain.sublist(i, i + dl));
      i += dl;
      final int ul = plain[i++];
      final String owner = utf8.decode(plain.sublist(i, i + ul));
      i += ul;
      if (i != plain.length || owner != userId || deviceId.isEmpty) return null;
      return BackedUpIdentity(owner, deviceId, seed);
    } catch (_) {
      return null;
    }
  }

  Future<bool> enabled() => prefs.enabled();

  /// True for "this phone has no such store" (not a failing one).
  static bool isUnavailable(Object e) =>
      e is MissingPluginException || (e is PlatformException && e.code == 'unavailable');

  /// Whether the store can be reached at all: [KeyBackupMiss.unavailable] (no copy can ever be kept here),
  /// [KeyBackupMiss.storeError] (failing right now), or null (works). Never throws, reads nothing real.
  Future<KeyBackupMiss?> reach() async {
    try {
      await store.read(await entryKey('probe')).timeout(timeout);
      return null;
    } catch (e) {
      return isUnavailable(e) ? KeyBackupMiss.unavailable : KeyBackupMiss.storeError;
    }
  }

  /// Tries the removals that failed earlier. True when nothing is left pending. Never throws.
  Future<bool> payPending() async {
    Set<String> pending;
    try {
      pending = await prefs.pendingRemovals();
    } catch (_) {
      return true;
    }
    if (pending.isEmpty) return true;
    final Set<String> left = <String>{};
    for (final String name in pending) {
      try {
        if (name == allEntries) {
          await store.deleteAll().timeout(timeout);
        } else {
          await store.delete(name).timeout(timeout);
        }
        _log('keybackup_removed', '${store.name} pending');
      } catch (e) {
        // A phone with no such store has nothing to remove.
        if (!isUnavailable(e)) left.add(name);
      }
    }
    try {
      await prefs.setPendingRemovals(left);
    } catch (_) {
      return false;
    }
    return left.isEmpty;
  }

  Future<void> _setPending(String name, bool pending) async {
    try {
      final Set<String> p = await prefs.pendingRemovals();
      if (pending ? p.add(name) : p.remove(name)) await prefs.setPendingRemovals(p);
    } catch (_) {}
  }

  /// Stores (replaces) the copy of [id]. Never throws.
  Future<bool> save(BackedUpIdentity id) async {
    try {
      if (!await prefs.enabled()) return false;
      final String secret = await store.phoneSecret().timeout(timeout);
      final String name = await entryKey(id.userId);
      await store.write(name, await seal(id, secret)).timeout(timeout);
      // The entry now holds the live key: an earlier failed removal of the old one is moot.
      await _setPending(name, false);
      _log('keybackup_saved', store.name);
      return true;
    } catch (e) {
      _log('keybackup_save_error', '${store.name} ${e.runtimeType}');
      return false;
    }
  }

  /// The copy for [userId], or null (the reason is in [lastMiss]). Never throws.
  Future<BackedUpIdentity?> load(String userId) async {
    lastMiss = null;
    try {
      if (!await prefs.enabled()) {
        lastMiss = KeyBackupMiss.off;
        return null;
      }
      final String name = await entryKey(userId);
      // A copy that was erased but could not be removed then is not a copy: never read it.
      if (!await payPending()) {
        final Set<String> p = await prefs.pendingRemovals();
        if (p.contains(name) || p.contains(allEntries)) {
          lastMiss = KeyBackupMiss.none;
          _log('keybackup_erased_pending', store.name);
          return null;
        }
      }
      final Uint8List? blob = await store.read(name).timeout(timeout);
      if (blob == null || blob.isEmpty) {
        lastMiss = KeyBackupMiss.none;
        return null;
      }
      final BackedUpIdentity? id = await open(blob, await store.phoneSecret().timeout(timeout), userId);
      if (id == null) {
        lastMiss = KeyBackupMiss.otherPhoneOrDamaged;
        _log('keybackup_unopened', store.name);
      }
      return id;
    } catch (e) {
      lastMiss = isUnavailable(e) ? KeyBackupMiss.unavailable : KeyBackupMiss.storeError;
      _log('keybackup_read_error', '${store.name} ${e.runtimeType}');
      return null;
    }
  }

  /// Removes the copy of [userId], or every copy when [userId] is empty (the owner could not be named). Never
  /// throws. A failure is remembered and paid before the next read or save ([payPending]), and returned as false.
  /// A phone with no such store has nothing to remove (true).
  Future<bool> remove(String userId) async {
    final String name = userId.isEmpty ? allEntries : await entryKey(userId);
    try {
      if (userId.isEmpty) {
        await store.deleteAll().timeout(timeout);
      } else {
        await store.delete(name).timeout(timeout);
      }
      await _setPending(name, false);
      _log('keybackup_removed', store.name);
      return true;
    } catch (e) {
      if (isUnavailable(e)) return true;
      await _setPending(name, true);
      _log('keybackup_remove_error', '${store.name} ${e.runtimeType}');
      return false;
    }
  }

  /// Turns the switch. Off removes every copy this app keeps on the phone.
  /// Returns false when removing failed (the switch is still off; the next
  /// start tries again through [E2eeService.syncKeyBackup]).
  Future<bool> setEnabled(bool on) async {
    await prefs.setEnabled(on);
    _log('keybackup_switch', on ? 'on' : 'off');
    if (on) return true;
    return removeAll();
  }

  /// Removes every copy. Never throws.
  Future<bool> removeAll() async {
    try {
      await store.deleteAll().timeout(timeout);
      _log('keybackup_removed', '${store.name} all');
      return true;
    } catch (e) {
      _log('keybackup_remove_error', '${store.name} all ${e.runtimeType}');
      return false;
    }
  }
}
