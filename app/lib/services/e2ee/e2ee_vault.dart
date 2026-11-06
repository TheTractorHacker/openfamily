import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the Android Keystore wrapping key lives.
enum KeystoreLevel { strongBox, tee, software, unavailable }

class KeystoreStatus {
  const KeystoreStatus({
    required this.level,
    this.unlockedDeviceRequired = false,
    this.userAuthRequired = false,
  });
  final KeystoreLevel level;
  final bool unlockedDeviceRequired;
  final bool userAuthRequired;

  String get label {
    switch (level) {
      case KeystoreLevel.strongBox:
        return 'StrongBox (dedicated security chip)';
      case KeystoreLevel.tee:
        return 'Trusted Execution Environment (TEE)';
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

/// Storage for the secrets of this phone (identity seed, circle keys).
abstract class E2eeVault {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List value);
  Future<void> delete(String name);
  Future<List<String>> names();
  Future<KeystoreStatus> status();
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

/// Thin wrapper over the native Android Keystore channel. The Keystore holds
/// ONE non-extractable AES-256-GCM key that encrypts the secrets before they are
/// written to disk. Ed25519, X25519 and XChaCha20 are NOT hardware-backed:
/// they run in app memory, and only the key that protects them at rest is.
class KeystoreChannel {
  const KeystoreChannel();
  static const MethodChannel _ch = MethodChannel('app.openfamily/keystore');

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
      rethrow;
    }
  }

  Future<KeystoreStatus> status() async {
    try {
      final Map<dynamic, dynamic>? m = await _ch.invokeMethod<Map<dynamic, dynamic>>('status');
      if (m == null) return const KeystoreStatus(level: KeystoreLevel.unavailable);
      final String l = (m['level'] as String?) ?? 'unavailable';
      return KeystoreStatus(
        level: switch (l) {
          'strongbox' => KeystoreLevel.strongBox,
          'tee' => KeystoreLevel.tee,
          'software' => KeystoreLevel.software,
          _ => KeystoreLevel.unavailable,
        },
        unlockedDeviceRequired: m['unlockedDeviceRequired'] == true,
        userAuthRequired: m['userAuthRequired'] == true,
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
            ),
        _channel = channel;

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
    // First byte: 1 = Keystore-wrapped, 0 = plain (fallback platforms).
    if (stored[0] == 1) {
      return _channel.decrypt(Uint8List.sublistView(stored, 1));
    }
    return Uint8List.sublistView(stored, 1);
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
        key: name, value: base64.encode(<int>[native ? 1 : 0, ...body]));
  }

  @override
  Future<void> delete(String name) => _storage.delete(key: name);

  @override
  Future<List<String>> names() async => (await _storage.readAll()).keys.toList();

  @override
  Future<KeystoreStatus> status() => _channel.status();
}

/// Blocks screenshots / recents thumbnails while a secret is on screen
/// (Android FLAG_SECURE). Best effort on other platforms.
class ScreenSecurity {
  const ScreenSecurity();
  static const MethodChannel _ch = MethodChannel('app.openfamily/keystore');
  Future<void> setSecure(bool on) async {
    try {
      await _ch.invokeMethod<void>('setSecure', on);
    } on MissingPluginException {
      // Not Android: nothing to do.
    } on PlatformException {
      // Ignore: the phrase screen still warns the user.
    }
  }
}
