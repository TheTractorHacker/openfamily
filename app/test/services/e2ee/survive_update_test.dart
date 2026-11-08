// Owner incident (recurring, Android, sideloaded updates signed with the same
// certificate): after an app update, and "every other while", the app showed
// the sign-in screen AND "This phone's encryption key can't be read", and the
// only way out was "Set this phone up again" (new key, admin re-approval).
//
// These tests pin the survival rules (docs/design/E2EE.md "Keys survive
// updates"): a storage or decrypt failure never deletes data, never reads as
// "no key", never makes a new identity and never signs the user out; blobs
// written by v0.25.2 / v0.26.0 (flag byte 2, 1 and 0) still open; a reset puts
// the key aside instead of destroying it.
import 'dart:convert';
import 'dart:io';


import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/storage_event_log.dart';
import 'package:openfamily/services/storage_self_check.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_e2ee_server.dart';

/// flutter_secure_storage as the plugin sees it: one map per preferences file
/// (`sharedPreferencesName`), and per-file switches for the failure modes of
/// the Android implementation.
class FakeSecurePlatform extends FlutterSecureStoragePlatform {
  final Map<String, Map<String, String>> files = <String, Map<String, String>>{};

  /// Files whose every call throws (a Keystore / Tink error surfaced as a PlatformException).
  final Set<String> throwing = <String>{};

  /// Files whose writes are silently dropped (the "stuck entry" phones).
  final Set<String> ignoreWrites = <String>{};
  int reads = 0;

  /// The preferences file a key lives in. On the Android device the file comes from the options; the host test
  /// runs on Linux, where the plugin passes LinuxOptions (no file name), so the key names tell the stores apart.
  static String fileOf(Map<String, String> o, [String? key]) {
    final String n = o['sharedPreferencesName'] ?? '';
    if (n.isNotEmpty) return n;
    if (key == null) return _vaultFile; // readAll / deleteAll: only the vault lists its names
    if (isVaultKeyMaterial(key) || key.startsWith('offline/') || key.startsWith('lastpos/')) return _vaultFile;
    if (key.startsWith('session_b_')) return 'openfamily_session_b';
    if (key.startsWith('saved_login_')) return 'openfamily_saved_login';
    return 'FlutterSecureStorage';
  }

  Map<String, String> _f(Map<String, String> o, [String? key]) {
    final String f = fileOf(o, key);
    if (throwing.contains(f)) throw PlatformException(code: 'Exception encountered', message: 'read');
    return files.putIfAbsent(f, () => <String, String>{});
  }

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async =>
      _f(options, key).containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async =>
      _f(options, key).remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => _f(options).clear();
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    reads++;
    return _f(options, key)[key];
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async =>
      Map<String, String>.of(_f(options));
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    final Map<String, String> m = _f(options, key);
    if (ignoreWrites.contains(fileOf(options, key))) return;
    m[key] = value;
  }
}

/// The e2ee_keystore plugin's contract, with switchable failures.
class FakeKeystore {
  /// PlatformException code for decrypt (e.g. 'keystore' = transient, 'invalidated').
  String? decryptError;
  int failNext = 0; // fail only the next N decrypts (transient)
  bool legacy = false;
  bool statusFails = false;
  bool brokenEncrypt = false; // encrypt returns something that does not open
  int decrypts = 0;

  static const int mask = 0x5a;
  static const int legacyMask = 0x33;
  static const int tagV2 = 0xA2;
  static const int tagV1 = 0xA1;

  Future<Object?> handle(MethodCall c) async {
    switch (c.method) {
      case 'encrypt':
        final Uint8List p = c.arguments as Uint8List;
        if (brokenEncrypt) return Uint8List.fromList(<int>[0, 0, 0]);
        return Uint8List.fromList(<int>[tagV2, ...p.map((int b) => b ^ mask)]);
      case 'decrypt':
        decrypts++;
        if (failNext > 0) {
          failNext--;
          throw PlatformException(code: 'keystore', message: 'KeyStoreException');
        }
        if (decryptError != null) throw PlatformException(code: decryptError!);
        final Uint8List b = c.arguments as Uint8List;
        // AES-GCM is authenticated: a blob of the other key (or garbage) never "opens" to wrong bytes.
        if (b.isEmpty || b[0] != tagV2) throw PlatformException(code: 'keystore', message: 'AEADBadTagException');
        return Uint8List.fromList(b.sublist(1).map((int x) => x ^ mask).toList());
      case 'decryptLegacy':
        if (!legacy) throw PlatformException(code: 'invalidated');
        final Uint8List b = c.arguments as Uint8List;
        if (b.isEmpty || b[0] != tagV1) throw PlatformException(code: 'keystore', message: 'AEADBadTagException');
        return Uint8List.fromList(b.sublist(1).map((int x) => x ^ legacyMask).toList());
      case 'deleteLegacy':
        legacy = false;
        return null;
      case 'status':
        if (statusFails) throw PlatformException(code: 'keystore');
        return <String, dynamic>{'level': 'tee', 'legacyKey': legacy, 'unlockedDeviceRequired': false, 'userAuthRequired': false};
    }
    throw MissingPluginException();
  }
}

const MethodChannel _chan = MethodChannel('test/survive-keystore');
const String _vaultFile = 'openfamily_e2ee';

String blob2(List<int> plain) =>
    base64.encode(<int>[2, FakeKeystore.tagV2, ...plain.map((int b) => b ^ FakeKeystore.mask)]);
String blob1(List<int> plain) =>
    base64.encode(<int>[1, FakeKeystore.tagV1, ...plain.map((int b) => b ^ FakeKeystore.legacyMask)]);
String blob1SameKey(List<int> plain) =>
    base64.encode(<int>[1, FakeKeystore.tagV2, ...plain.map((int b) => b ^ FakeKeystore.mask)]);
String blob0(List<int> plain) => base64.encode(<int>[0, ...plain]);

late FakeSecurePlatform platform;
late FakeKeystore ks;
late MemoryVaultMirror mirror;

SecureVault vault({VaultMirror? m, bool noMirror = false}) => SecureVault(
      storage: SecureVault.defaultStorage,
      channel: const KeystoreChannel(channel: _chan),
      mirror: noMirror ? null : (m ?? mirror),
      useMirror: !noMirror,
      retryDelays: const <Duration>[Duration.zero, Duration.zero],
    );

Map<String, String> get vaultFile => platform.files.putIfAbsent(_vaultFile, () => <String, String>{});

Future<List<String>> events() => StorageEventLog.instance.events();

final Uint8List seed = Uint8List.fromList(List<int>.generate(32, (int i) => i + 7));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    platform = FakeSecurePlatform();
    FlutterSecureStoragePlatform.instance = platform;
    ks = FakeKeystore();
    mirror = MemoryVaultMirror();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_chan, ks.handle);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageEventLog.instance.resetForTest();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_chan, null);
  });

  group('H1: no secure-storage options may reset data on error', () {
    test('every AndroidOptions in lib/ spells out resetOnError: false', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String src = f.readAsStringSync();
        int i = src.indexOf('AndroidOptions(');
        while (i >= 0) {
          final int end = src.indexOf(')', i);
          final String args = src.substring(i, end < 0 ? src.length : end);
          if (!args.contains('resetOnError: false')) offenders.add(f.path);
          i = src.indexOf('AndroidOptions(', i + 1);
        }
      }
      expect(offenders, isEmpty);
      expect(SecureVault.defaultStorage.aOptions.toMap()['resetOnError'], 'false');
    });
  });

  group('Blob formats written by v0.25.2 / v0.26.0 still open', () {
    test('flag 2 (current key) opens and is mirrored', () async {
      vaultFile['identity_seed'] = blob2(seed);
      expect(await vault().read('identity_seed'), seed);
      expect(mirror.data['live/identity_seed'], vaultFile['identity_seed']);
    });

    test('flag 1 with the old (v1) Android key opens through decryptLegacy', () async {
      ks.legacy = true;
      vaultFile['identity_seed'] = blob1(seed);
      expect(await vault().read('identity_seed'), seed);
    });

    test('flag 1 when the status call fails still opens (the old key is tried too)', () async {
      ks.legacy = true;
      ks.statusFails = true;
      vaultFile['identity_seed'] = blob1(seed);
      expect(await vault().read('identity_seed'), seed);
    });

    test('flag 1 without a legacy key (iOS, same key) opens with the current key', () async {
      vaultFile['identity_seed'] = blob1SameKey(seed);
      expect(await vault().read('identity_seed'), seed);
    });

    test('flag 0 (plain fallback platform) opens and is never mirrored in plain prefs', () async {
      vaultFile['identity_seed'] = blob0(seed);
      expect(await vault().read('identity_seed'), seed);
      expect(mirror.data, isEmpty);
    });

    test('migrateLegacy re-wraps v1 blobs and keeps the mirror current', () async {
      ks.legacy = true;
      vaultFile['identity_seed'] = blob1(seed);
      vaultFile['offline/v1/x'] = blob1(<int>[1, 2]);
      expect(await vault().migrateLegacy(), VaultMigration.done);
      expect(base64.decode(vaultFile['identity_seed']!)[0], 2);
      expect(mirror.data['live/identity_seed'], vaultFile['identity_seed']);
      expect(mirror.data.keys.where((String k) => k.startsWith('prev/')), isEmpty);
      expect(await vault().read('identity_seed'), seed);
    });
  });

  group('A decrypt or storage failure is never "no key" and never deletes', () {
    test('a transient Keystore error is retried and then succeeds', () async {
      vaultFile['identity_seed'] = blob2(seed);
      ks.failNext = 2;
      expect(await vault().read('identity_seed'), seed);
      expect((await events()).where((String e) => e.contains('decrypt_error')), hasLength(2));
    });

    test('a persistent decrypt failure throws VaultUnreadableException and keeps the blob', () async {
      final String stored = blob2(seed);
      vaultFile['identity_seed'] = stored;
      ks.decryptError = 'keystore';
      await expectLater(vault().read('identity_seed'), throwsA(isA<VaultUnreadableException>()));
      expect(ks.decrypts, 3, reason: 'bounded retries');
      expect(vaultFile['identity_seed'], stored, reason: 'nothing deleted or rewritten');
      expect((await events()).any((String e) => e.contains('read_failed')), isTrue);
    });

    test('the secure store throwing reads the mirror copy (no data loss)', () async {
      vaultFile['identity_seed'] = blob2(seed);
      await vault().read('identity_seed'); // backfills the mirror
      platform.throwing.add(_vaultFile);
      expect(await vault().read('identity_seed'), seed);
      expect((await events()).any((String e) => e.contains('mirror_hit') && e.contains('primary=error')), isTrue);
    });

    test('the secure store throwing with no mirror copy throws, never returns null', () async {
      platform.throwing.add(_vaultFile);
      await expectLater(vault().read('identity_seed'), throwsA(isA<VaultUnreadableException>()));
    });

    test('EncryptedSharedPreferences reading as EMPTY (plugin fallback) uses the mirror and heals the store', () async {
      vaultFile['identity_seed'] = blob2(seed);
      vaultFile['device_id'] = blob2(utf8.encode('dev-1'));
      final SecureVault v = vault();
      await v.read('identity_seed');
      await v.read('device_id');
      vaultFile.clear(); // the plugin's silent fallback: every key reads null
      expect(await v.read('identity_seed'), seed);
      expect(vaultFile['identity_seed'], isNotNull, reason: 'healed from the mirror');
      expect(await v.names(), containsAll(<String>['identity_seed', 'device_id']));
    });

    test('ordinary data (offline cache) keeps the old simple behaviour', () async {
      final SecureVault v = vault();
      await v.write('offline/v1/a', Uint8List.fromList(<int>[1]));
      expect(mirror.data, isEmpty);
      await v.delete('offline/v1/a');
      expect(await v.read('offline/v1/a'), isNull);
    });
  });

  group('Write-verify-swap', () {
    test('a write the store ignores still lands in the mirror; the old blob is kept until verified', () async {
      final SecureVault v = vault();
      await v.write('identity_seed', seed);
      platform.ignoreWrites.add(_vaultFile);
      final Uint8List next = Uint8List.fromList(List<int>.filled(32, 9));
      await v.write('identity_seed', next);
      expect(mirror.data['live/identity_seed'], blob2(next));
      expect(mirror.data.containsKey('prev/identity_seed'), isFalse, reason: 'swapped after the mirror verified');
      expect((await events()).any((String e) => e.contains('readback_mismatch')), isTrue);
    });

    test('a new blob that does not open never replaces the old one', () async {
      final SecureVault v = vault();
      await v.write('identity_seed', seed);
      ks.brokenEncrypt = true;
      await expectLater(v.write('identity_seed', Uint8List.fromList(List<int>.filled(32, 1))),
          throwsA(isA<VaultUnreadableException>()));
      ks.brokenEncrypt = false;
      expect(await v.read('identity_seed'), seed);
    });

    test('when neither store keeps the new blob, the old one is put back and the write fails loudly', () async {
      final SecureVault v = vault();
      await v.write('identity_seed', seed);
      platform.ignoreWrites.add(_vaultFile);
      mirror.failAll = true;
      await expectLater(v.write('identity_seed', Uint8List.fromList(List<int>.filled(32, 1))), throwsStateError);
      mirror.failAll = false;
      platform.ignoreWrites.clear();
      expect(await v.read('identity_seed'), seed);
    });
  });

  group('Delete archives key material', () {
    test('delete puts the blob aside; it can be read back from the archive', () async {
      final SecureVault v = vault();
      await v.write('identity_seed', seed);
      await v.delete('identity_seed');
      expect(await v.read('identity_seed'), isNull);
      final List<VaultArchiveSet> sets = await v.archives();
      expect(sets, hasLength(1));
      expect(await v.readArchived(sets.first.id, 'identity_seed'), seed);
    });

    test('at most maxArchives sets are kept', () async {
      final SecureVault v = vault();
      for (int i = 0; i < SecureVault.maxArchives + 2; i++) {
        await v.write('device_id', Uint8List.fromList(<int>[i]));
        await v.archiveNames(<String>['device_id']);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(await v.archives(), hasLength(SecureVault.maxArchives));
    });
  });

  group('E2eeService never regenerates or wipes on a read failure', () {
    late FakeE2eeServer server;
    setUp(() => server = FakeE2eeServer());

    E2eeService svc(E2eeVault v, {String user = 'u1'}) =>
        E2eeService(api: server.client(user), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);

    test('unreadable stored key: identity(create: true) throws and the blobs stay', () async {
      final SecureVault v = vault();
      final LocalIdentity first = (await svc(v).identity(create: true))!;
      final Map<String, String> before = Map<String, String>.of(vaultFile);
      ks.decryptError = 'keystore';
      await expectLater(svc(v).identity(create: true),
          throwsA(isA<LocalKeyException>().having((LocalKeyException e) => e.problem, 'problem', LocalKeyProblem.unreadable)));
      expect(vaultFile, before, reason: 'nothing deleted, nothing regenerated');
      ks.decryptError = null;
      expect((await svc(v).identity())!.fingerprintHex, first.fingerprintHex);
    });

    test('a seed without its device id is a partial read, never a new identity', () async {
      final MemoryVault v = MemoryVault();
      await v.write('identity_seed', seed);
      await v.write('identity_user', Uint8List.fromList(utf8.encode('u1')));
      await expectLater(svc(v).identity(create: true), throwsA(isA<LocalKeyException>()));
      expect(v.data['identity_seed'], seed);
    });

    test('"Set this phone up again" archives; the old key can be brought back once readable', () async {
      final SecureVault v = vault();
      final E2eeService s = svc(v);
      final LocalIdentity first = (await s.identity(create: true))!;
      await s.eraseLocalKeys();
      final E2eeService s2 = svc(v);
      expect(await s2.identity(), isNull);
      final VaultArchiveSet? set = await s2.restorableIdentity();
      expect(set, isNotNull);
      await s2.restoreArchivedIdentity(set!);
      expect((await svc(v).identity())!.fingerprintHex, first.fingerprintHex);
      expect((await events()).any((String e) => e.contains('identity_restored')), isTrue);
    });

    test('another account signing in archives (not destroys) the first one', () async {
      final MemoryVault v = MemoryVault();
      final LocalIdentity a = (await svc(v, user: 'u1').identity(create: true))!;
      await svc(v, user: 'u2').identity(create: true);
      expect(v.archived.values.any((Map<String, Uint8List> m) => m.containsKey('identity_seed')), isTrue);
      // Back on u1: the restorable set is u1's and gives the same key.
      final E2eeVault fresh = MemoryVault()..archived.addAll(v.archived);
      final E2eeService back = svc(fresh, user: 'u1');
      final VaultArchiveSet? set = await back.restorableIdentity();
      expect(set, isNotNull);
      await back.restoreArchivedIdentity(set!);
      expect((await svc(fresh, user: 'u1').identity())!.fingerprintHex, a.fingerprintHex);
    });

    test('a restore never overwrites a live identity', () async {
      final MemoryVault v = MemoryVault();
      final E2eeService s = svc(v);
      await s.identity(create: true);
      await s.eraseLocalKeys();
      final VaultArchiveSet set = (await v.archives()).first;
      await svc(v).identity(create: true);
      await expectLater(svc(v).restoreArchivedIdentity(set), throwsStateError);
    });
  });

  group('H4: storage errors never sign out', () {
    setUp(() async {
      TokenStorage.resetForTest();
      TokenStorage.retryDelays = const <Duration>[Duration.zero, Duration.zero];
      SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
      await ServerConfig.instance.load();
      ApiClient.invalidateConfig();
      ApiClient.markSessionActive();
      ApiClient.onSessionExpired = null;
    });

    http.Client expiredServer(List<String> refreshCalls) => MockClient((http.Request r) async {
          if (r.url.path == '/auth/refresh') {
            refreshCalls.add(r.body);
            return http.Response('{"error":"invalid refresh token"}', 401);
          }
          return http.Response('{"error":"expired"}', 401);
        });

    test('every Keystore store throwing: no refresh, no sign-out, tokens still there afterwards', () async {
      platform.files['FlutterSecureStorage'] = <String, String>{
        'access_token_v2': 'old.access',
        'refresh_token_v2': 'old.refresh',
      };
      platform.throwing.addAll(<String>['FlutterSecureStorage', 'openfamily_session_b', 'openfamily_saved_login']);
      bool expired = false;
      ApiClient.onSessionExpired = () => expired = true;
      final List<String> calls = <String>[];
      await http.runWithClient(() async {
        await expectLater(ApiClient.get('/family'), throwsA(isA<ApiException>()));
      }, () => expiredServer(calls));
      expect(expired, isFalse);
      expect(calls, isEmpty, reason: 'nothing to refresh with, so nothing was learned');
      platform.throwing.clear();
      expect(await TokenStorage.readRefreshToken(), 'old.refresh');
      expect((await events()).any((String e) => e.contains('refresh_skipped')), isTrue);
    });

    for (final int status in <int>[400, 403]) {
      test('refresh answered $status (proxy, captive portal) keeps the session', () async {
        platform.files['FlutterSecureStorage'] = <String, String>{
          'access_token_v2': 'old.access',
          'refresh_token_v2': 'old.refresh',
        };
        bool expired = false;
        ApiClient.onSessionExpired = () => expired = true;
        await http.runWithClient(() async {
          await expectLater(ApiClient.get('/family'), throwsA(isA<ApiException>()));
        }, () => MockClient((http.Request r) async => http.Response('{"error":"x"}', r.url.path == '/auth/refresh' ? status : 401)));
        expect(expired, isFalse);
        expect(await TokenStorage.readRefreshToken(), 'old.refresh');
      });
    }

    test('a sign-out after the server says 401 records its reason', () async {
      platform.files['FlutterSecureStorage'] = <String, String>{
        'access_token_v2': 'old.access',
        'refresh_token_v2': 'old.refresh',
      };
      await http.runWithClient(() async {
        await expectLater(ApiClient.get('/family'), throwsA(isA<SessionExpiredException>()));
      }, () => expiredServer(<String>[]));
      expect((await events()).any((String e) => e.contains('signout') && e.contains('refresh rejected')), isTrue);
    });
  });

  group('Startup self-check and event log', () {
    test('records which stores hold tokens and whether the identity opens', () async {
      final SecureVault v = vault();
      await v.write('identity_seed', seed);
      await v.write('device_id', Uint8List.fromList(utf8.encode('d')));
      await v.write('ck/c1/1', Uint8List.fromList(List<int>.filled(32, 3)));
      final String line = await StorageSelfCheck.run(
        readTokens: () async => const <StoredSession>[
          StoredSession(source: 'D', access: 'a', refresh: 'r'),
        ],
        readErrors: () => const <String, String>{'A': 'PlatformException'},
        vault: v,
      );
      expect(line, 'tokens=D token_errors=A identity=ok keys=1');
      expect((await events()).last, contains('selfcheck'));
    });

    test('an unreadable identity is reported, not repaired', () async {
      final SecureVault v = vault();
      await v.write('identity_seed', seed);
      ks.decryptError = 'keystore';
      final String line = await StorageSelfCheck.run(
          readTokens: () async => const <StoredSession>[], readErrors: () => const <String, String>{}, vault: v);
      expect(line, contains('identity=unreadable(decrypt)'));
      expect(vaultFile['identity_seed'], isNotNull);
    });

    test('the log keeps the last 50 events and never more', () async {
      for (int i = 0; i < 60; i++) {
        StorageEventLog.instance.record('e$i');
      }
      final List<String> list = await events();
      expect(list, hasLength(StorageEventLog.maxEvents));
      expect(list.last, endsWith('e59'));
      expect(await StorageEventLog.instance.render(), contains('Storage events (last 50'));
    });
  });
}
