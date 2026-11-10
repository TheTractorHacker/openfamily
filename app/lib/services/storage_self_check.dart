import 'dart:convert';
import 'dart:typed_data';

import 'e2ee/e2ee_vault.dart';
import 'storage_event_log.dart';
import 'token_storage.dart';

/// One-time startup check (foreground engine): can this phone read its
/// sign-in tokens and its encryption identity? The answer goes to the
/// [StorageEventLog] as reason codes only, so an incident after an update can
/// be traced to the store that failed. Reading the key material also copies
/// any blob written before the mirror existed into the mirror (backfill).
///
/// Never writes a token, never creates or deletes a key.
class StorageSelfCheck {
  StorageSelfCheck._();

  static bool _ran = false;

  /// Runs [run] once per process. Never throws.
  static Future<String?> runOnce() async {
    if (_ran) return null;
    _ran = true;
    try {
      return await run();
    } catch (e) {
      StorageEventLog.instance.record('selfcheck_error', detail: e.runtimeType.toString());
      return null;
    }
  }

  /// The check itself; returns the recorded summary line. Test seams: [readTokens]
  /// and [readErrors] replace [TokenStorage], [vault] replaces the production vault.
  static Future<String> run({
    Future<List<StoredSession>> Function()? readTokens,
    Map<String, String> Function()? readErrors,
    E2eeVault? vault,
  }) async {
    // Tokens: which stores hold a pair, which failed.
    String tokens;
    try {
      final List<StoredSession> stores = await (readTokens ?? TokenStorage.readAllStores)();
      final Map<String, String> errs = (readErrors ?? () => TokenStorage.lastReadErrors)();
      final String held = stores.where((StoredSession s) => s.source != 'M').map((StoredSession s) => s.source).join(',');
      tokens = 'tokens=${held.isEmpty ? 'none' : held}'
          '${errs.isEmpty ? '' : ' token_errors=${errs.keys.join(',')}'}';
    } catch (e) {
      tokens = 'tokens=error(${e.runtimeType})';
    }

    // Identity and the other key material.
    final E2eeVault v = vault ?? SecureVault();
    String identity;
    String owner = '';
    int keys = 0;
    int bad = 0;
    try {
      final Uint8List? seed = await v.read('identity_seed');
      final Uint8List? device = seed == null ? null : await v.read('device_id');
      identity = seed == null ? 'none' : (device == null ? 'partial' : 'ok');
      // The same content checks identity() makes, read-only: a stored key that opens but is not usable must not say ok.
      if (seed != null && device != null) {
        if (seed.length != 32) {
          identity = 'bad(seed_len)';
        } else if (!_isText(device)) {
          identity = 'bad(device_format)';
        }
      }
      if (seed != null) owner = await _owner(v);
      for (final String n in await v.names()) {
        if (!isVaultKeyMaterial(n) || n == 'identity_seed' || n == 'device_id' || n == 'identity_user') continue;
        try {
          await v.read(n);
          keys++;
        } catch (_) {
          bad++;
        }
      }
    } on VaultLockedException {
      identity = 'locked';
    } on VaultInvalidatedException {
      identity = 'invalidated';
    } on VaultUnreadableException catch (e) {
      identity = 'unreadable(${e.stage})';
    } catch (e) {
      identity = 'unreadable(${e.runtimeType})';
    }
    final String line = '$tokens identity=$identity${owner.isEmpty ? '' : ' owner=$owner'} keys=$keys${bad == 0 ? '' : ' unreadable_keys=$bad'}';
    StorageEventLog.instance.record('selfcheck', detail: line);
    return line;
  }

  static bool _isText(Uint8List b) {
    try {
      utf8.decode(b);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// The account note next to the key: `ok`, `missing`, `empty`, `garbled` or `unreadable(stage)`. Never throws.
  static Future<String> _owner(E2eeVault v) async {
    try {
      final Uint8List? raw = await v.read('identity_user');
      if (raw == null) return 'missing';
      if (raw.isEmpty) return 'empty';
      return _isText(raw) ? 'ok' : 'garbled';
    } on VaultUnreadableException catch (e) {
      return 'unreadable(${e.stage})';
    } on VaultLockedException {
      return 'locked';
    } on VaultInvalidatedException {
      return 'invalidated';
    } catch (e) {
      return 'unreadable(${e.runtimeType})';
    }
  }

  /// Test hook.
  static void resetForTest() => _ran = false;
}
