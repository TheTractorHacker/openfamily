import 'package:shared_preferences/shared_preferences.dart';

import '../circle_service.dart';
import 'e2ee_api.dart';
import 'e2ee_service.dart';
import 'e2ee_trust.dart';
import 'e2ee_vault.dart';
import 'key_backup.dart';
import 'private_channel.dart';
import 'private_runtime.dart';

/// SharedPreferences-backed [TrustKv]. Holds public fingerprints and the pinned
/// log head only. (Cleared with app data, which also clears the private keys.)
class PrefsTrustKv implements TrustKv {
  static const String _p = 'e2ee_trust_';
  @override
  Future<String?> get(String key) async => (await SharedPreferences.getInstance()).getString('$_p$key');
  @override
  Future<void> set(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString('$_p$key', value);
  @override
  Future<void> remove(String key) async => (await SharedPreferences.getInstance()).remove('$_p$key');
}

/// The app-wide E2EE service. Tests inject their own through [override].
class E2eeApp {
  E2eeApp._();
  static E2eeService? override;
  static E2eeService? _service;

  static E2eeService get service => override ?? (_service ??= E2eeService(
        api: const ApiE2eeApi(),
        vault: SecureVault(),
        trust: TrustStore(PrefsTrustKv()),
        userIdProvider: () => CircleService.instance.myUserId(),
        keyBackup: keyBackup,
        onPlatformRestore: (String deviceId) => const PrefsChannelKv()
            .set(ChannelSealer.seqFloorKey(deviceId), '${ChannelSealer.seqFloorNow(DateTime.now())}'),
      ));

  static KeyBackup? _keyBackup;
  static bool _keyBackupMade = false;

  /// "Keep this phone's key safe through reinstalls" (Android Block Store, iOS Keychain), or null where the
  /// platform has no such store. Tests inject theirs through [override] instead.
  static KeyBackup? get keyBackup {
    if (!_keyBackupMade) {
      _keyBackupMade = true;
      final PlatformKeyStore? store = KeyBackup.platformStore();
      _keyBackup = store == null ? null : KeyBackup(store: store);
    }
    return _keyBackup;
  }

  static void reset() => _service = null;
}

/// The inviter fingerprint that travels in invite links and QR codes, so the
/// joiner can check the keys the server later returns against a value that never
/// came from the server.
class InviteAnchor {
  InviteAnchor._();

  static Future<String?> myFingerprint() async {
    try {
      return await E2eeApp.service.inviteFingerprint();
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String? fingerprintHex) async {
    if (fingerprintHex == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprintHex)) return;
    await E2eeApp.service.trust.savePendingInviter(fingerprintHex);
  }
}
