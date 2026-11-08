import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

class MemoryVault implements E2eeVault {
  final Map<String, Uint8List> data = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String name) async => data[name];
  @override
  Future<void> write(String name, Uint8List value) async => data[name] = Uint8List.fromList(value);
  @override
  Future<void> delete(String name) async => data.remove(name);
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

/// Production vault: AES-256-GCM (Keystore key) over the secret, stored in
/// flutter_secure_storage. Without the native channel (non-Android, tests on a
/// host) it falls back to flutter_secure_storage alone and reports that.
class SecureVault implements E2eeVault {
  SecureVault({FlutterSecureStorage? storage, KeystoreChannel channel = const KeystoreChannel()})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                sharedPreferencesName: 'openfamily_e2ee',
                preferencesKeyPrefix: 'e2ee_',
              ),
              // iOS: a dedicated Keychain namespace (so names()/readAll never
              // lists tokens), readable after the first unlock so the
              // background isolate can seal location while the phone is locked,
              // this device only (no backup migration) and never iCloud-synced.
              iOptions: iosVaultOptions,
            ),
        _channel = channel;

  /// Keychain options of the vault blobs on iOS. See docs/design/E2EE.md.
  static const IOSOptions iosVaultOptions = IOSOptions(
    accountName: 'openfamily_e2ee',
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  final FlutterSecureStorage _storage;
  final KeystoreChannel _channel;
  bool? _native;

  Future<bool> _hasNative() async =>
      _native ??= (await _channel.status()).level != KeystoreLevel.unavailable;

  @override
  Future<Uint8List?> read(String name) async {
    final String? raw = await _storage.read(key: name);
    if (raw == null) return null;
    final Uint8List stored = base64.decode(raw);
    if (stored.isEmpty) return null;
    // First byte: 2 = wrapped with the current key (usable with the phone locked), 1 = wrapped by an older app
    // version (Android: the unlocked-device-only key, until migrateLegacy re-wraps it), 0 = plain (fallback platforms).
    final Uint8List body = Uint8List.sublistView(stored, 1);
    if (stored[0] == 1 && (await _channel.status()).legacyKey) return _channel.decryptLegacy(body);
    if (stored[0] == 1 || stored[0] == 2) return _channel.decrypt(body);
    return body;
  }

  @override
  Future<void> write(String name, Uint8List value) async {
    final bool native = await _hasNative();
    final Uint8List body = native ? await _channel.encrypt(value) : value;
    if (!native && !kDebugMode) {
      // On a platform without the Keystore channel keep going: the secure
      // storage plugin still encrypts at rest; the UI reports "not available".
    }
    await _storage.write(
        key: name, value: base64.encode(<int>[native ? 2 : 0, ...body]));
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
        await _storage.write(key: e.key, value: base64.encode(<int>[2, ...wrapped]));
        // Read back through the normal path; restore the old blob if it does not match.
        bool same = false;
        try {
          final Uint8List? back = await read(e.key);
          same = back != null && listEquals(back, plain);
        } catch (_) {}
        if (!same) {
          await _storage.write(key: e.key, value: e.value);
          return VaultMigration.failedKept;
        }
      }
      final Map<String, String> after = await _storage.readAll();
      final bool anyOld = after.values.any((String v) {
        final Uint8List b = base64.decode(v);
        return b.isNotEmpty && b[0] == 1;
      });
      if (anyOld) return VaultMigration.failedKept;
      await _channel.deleteLegacy();
      return VaultMigration.done;
    } on VaultLockedException {
      return VaultMigration.waitingForUnlock;
    } catch (_) {
      // Invalidated legacy key or a platform error: keep every blob exactly as it was. The normal read path
      // reports the invalidation and the app asks for the recovery phrase; nothing is regenerated here.
      return VaultMigration.failedKept;
    }
  }

  @override
  Future<void> delete(String name) => _storage.delete(key: name);

  @override
  Future<List<String>> names() async => (await _storage.readAll()).keys.toList();

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
