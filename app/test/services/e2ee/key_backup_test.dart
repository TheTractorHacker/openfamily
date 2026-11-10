import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/key_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_e2ee_server.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

/// A client whose key list can fail like a phone without a connection.
class FlakyClient extends FakeE2eeClient {
  FlakyClient(super.s, super.uid);
  bool offline = false;
  int myKeysCalls = 0;
  @override
  Future<List<DeviceKey>> myKeys() async {
    myKeysCalls++;
    if (offline) throw StateError('offline');
    return super.myKeys();
  }
}

/// One install of the app on one phone: a fresh vault (an uninstall deletes it) over the phone's platform store,
/// which survives the uninstall.
class Install {
  Install(FakeE2eeServer server, this.user, this.store, {KeyBackupPrefs? prefs, bool withBackup = true})
      : vault = MemoryVault(),
        prefs = prefs ?? MemoryKeyBackupPrefs() {
    api = FlakyClient(server, user);
    backup = withBackup ? KeyBackup(store: store, prefs: this.prefs) : null;
    svc = E2eeService(
      api: api,
      vault: vault,
      trust: TrustStore(MemoryTrustKv()),
      userIdProvider: () async => user,
      keyBackup: backup,
      onPlatformRestore: (String d) async => restoredDevices.add(d),
    );
  }
  final String user;
  final MemoryPlatformKeyStore store;
  final MemoryVault vault;
  final KeyBackupPrefs prefs;
  late final FlakyClient api;
  late final KeyBackup? backup;
  late final E2eeService svc;
  final List<String> restoredDevices = <String>[];
}

void main() {
  late FakeE2eeServer server;
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
  });

  /// A phone that set up encryption, registered and saved its copy.
  Future<(Install, LocalIdentity)> registered(MemoryPlatformKeyStore phone, {String user = uA}) async {
    final Install first = Install(server, user, phone);
    await first.svc.registerThisDevice(label: 'This phone');
    final LocalIdentity id = (await first.svc.identity())!;
    await first.svc.keyBackupSync;
    return (first, id);
  }

  group('blob', () {
    test('opens only with the same seal value and account, and carries no readable ids', () async {
      final Uint8List seed = E2ee.randomBytes(32);
      final Uint8List blob = await KeyBackup.seal(BackedUpIdentity(uA, 'dev-1', seed), 'phone-1');
      expect(blob[0], KeyBackup.version);
      expect(String.fromCharCodes(blob).contains(uA), isFalse);
      expect(String.fromCharCodes(blob).contains('dev-1'), isFalse);
      final BackedUpIdentity? ok = await KeyBackup.open(blob, 'phone-1', uA);
      expect(ok!.deviceId, 'dev-1');
      expect(E2ee.hex(ok.seed), E2ee.hex(seed));
      expect(await KeyBackup.open(blob, 'phone-2', uA), isNull, reason: 'another seal value');
      expect(await KeyBackup.open(blob, 'phone-1', uB), isNull, reason: 'another account');
      final Uint8List bad = Uint8List.fromList(blob)..[blob.length - 1] ^= 1;
      expect(await KeyBackup.open(bad, 'phone-1', uA), isNull, reason: 'damaged');
      expect(await KeyBackup.open(Uint8List.fromList(<int>[9, ...blob.skip(1)]), 'phone-1', uA), isNull,
          reason: 'unknown version');
    });

    test('entry names are per account and do not contain the account id', () async {
      final String a = await KeyBackup.entryKey(uA), b = await KeyBackup.entryKey(uB);
      expect(a, isNot(b));
      expect(a.contains(uA), isFalse);
      expect(RegExp(r'^[a-z0-9_]+$').hasMatch(a), isTrue);
    });
  });

  test('iOS: its own Keychain service, survives a reinstall and a device restore, never iCloud Keychain, and not wiped on a fresh install', () {
    final Map<String, String> m = KeychainKeyStore.defaultStorage.iOptions.toMap();
    expect(m['accessibility'], 'first_unlock', reason: 'not ThisDeviceOnly');
    expect(m['synchronizable'], 'false');
    expect(m['accountName'], 'openfamily_key_backup');
    final String swift = File('ios/Runner/SecureKeyChannel.swift').readAsStringSync();
    final String wiped = RegExp(r'storageServices = \[([^\]]*)\]').firstMatch(swift)!.group(1)!;
    expect(wiped, contains('openfamily_e2ee'));
    expect(wiped.contains('openfamily_key_backup'), isFalse);
  });

  group('restore after a reinstall', () {
    test('same account, device active on the server: the same identity comes back, no re-approval', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity before) = await registered(phone);
      expect(phone.data, hasLength(1));
      final int keysBefore = server.keys[uA]!.length;

      // Uninstall + reinstall: the vault is gone, the platform store is not.
      final Install again = Install(server, uA, phone);
      expect(await again.svc.hasIdentity(), isFalse);
      final LocalIdentity? after = await again.svc.identity();
      expect(after, isNotNull);
      expect(after!.deviceId, before.deviceId);
      expect(after.fingerprintHex, before.fingerprintHex);
      expect(await again.svc.hasIdentity(), isTrue);
      expect(again.restoredDevices, <String>[before.deviceId]);
      // Nothing registered, nothing to approve: the server's record matches as it is.
      final ServerRecordCheck check = await again.svc.checkServerRecord();
      expect(check.match, isTrue);
      final DeviceKey k = await again.svc.registerThisDevice(label: 'This phone');
      expect(k.deviceId, before.deviceId);
      expect(server.keys[uA]!.length, keysBefore);
    });

    test('the restored phone reads its circle keys again from the wraps the server still holds', () async {
      server.circle(circle, members: <String>[uA, uB], admin: uA);
      final MemoryPlatformKeyStore phoneA = MemoryPlatformKeyStore(secret: 'a');
      final (Install a, LocalIdentity _) = await registered(phoneA);
      final Install b = Install(server, uB, MemoryPlatformKeyStore(secret: 'b'));
      await b.svc.registerThisDevice();
      expect(await a.svc.enableCircle(circle), 1);
      final Uint8List? key = await a.svc.circleKey(circle, 1);

      final Install again = Install(server, uA, phoneA);
      expect(await again.svc.identity(), isNotNull);
      expect(await again.svc.syncCircleKeys(circle), 1);
      expect(E2ee.hex((await again.svc.circleKey(circle, 1))!), E2ee.hex(key!));
    });

    test('refused when the server says the device was revoked (reset elsewhere): a fresh key replaces the copy',
        () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install first, LocalIdentity before) = await registered(phone);
      await first.svc.revokeKey(server.keys[uA]!.single);

      final Install again = Install(server, uA, phone);
      expect(await again.svc.identity(), isNull);
      expect(again.restoredDevices, isEmpty);
      expect(await again.svc.hasIdentity(), isFalse);
      final LocalIdentity fresh = (await again.svc.identity(create: true))!;
      expect(fresh.deviceId, isNot(before.deviceId));
      // The copy now holds the new key, so the revoked one can never come back.
      final BackedUpIdentity? copy = await again.backup!.load(uA);
      expect(copy!.deviceId, fresh.deviceId);
    });

    test('refused when the server does not know the device id', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final Install first = Install(server, uA, phone);
      // Created and copied, but never registered.
      final LocalIdentity unregistered = (await first.svc.identity(create: true))!;
      expect(phone.data, hasLength(1));
      final Install again = Install(server, uA, phone);
      expect(await again.svc.identity(), isNull);
      final LocalIdentity fresh = (await again.svc.identity(create: true))!;
      expect(fresh.deviceId, isNot(unregistered.deviceId));
    });

    test('refused when the server holds other public keys for that device id', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity before) = await registered(phone);
      // Swap the seed in the copy for another one with the same device id and account.
      await phone.write(await KeyBackup.entryKey(uA),
          await KeyBackup.seal(BackedUpIdentity(uA, before.deviceId, E2ee.randomBytes(32)), phone.secret));
      final Install again = Install(server, uA, phone);
      expect(await again.svc.identity(), isNull);
      expect(again.restoredDevices, isEmpty);
    });

    test('a different account signing in neither restores nor deletes the copy', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity a) = await registered(phone);
      final Uint8List copyA = phone.data[await KeyBackup.entryKey(uA)]!;

      final Install bob = Install(server, uB, phone);
      expect(await bob.svc.identity(), isNull);
      final LocalIdentity b = (await bob.svc.identity(create: true))!;
      expect(b.deviceId, isNot(a.deviceId));
      expect(E2ee.hex(phone.data[await KeyBackup.entryKey(uA)]!), E2ee.hex(copyA));
      expect(phone.data, hasLength(2));

      // Alice signs back in on a reinstall: still hers.
      final Install alice = Install(server, uA, phone);
      expect((await alice.svc.identity())!.deviceId, a.deviceId);
    });

    test('a copy that reached a new phone (restored from the cloud backup) restores while the server lists the key',
        () async {
      final MemoryPlatformKeyStore oldPhone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity before) = await registered(oldPhone);
      final MemoryPlatformKeyStore newPhone = MemoryPlatformKeyStore()..data.addAll(oldPhone.data);
      final Install onNew = Install(server, uA, newPhone);
      expect((await onNew.svc.identity())!.deviceId, before.deviceId);
      expect(onNew.restoredDevices, <String>[before.deviceId]);
    });

    test('a damaged copy does not open and a fresh identity follows', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity before) = await registered(phone);
      final String k = await KeyBackup.entryKey(uA);
      phone.data[k] = Uint8List.fromList(phone.data[k]!)..[40] ^= 1;
      final Install again = Install(server, uA, phone);
      expect(await again.svc.identity(), isNull);
      expect(again.backup!.lastMiss, KeyBackupMiss.otherPhoneOrDamaged);
      final LocalIdentity fresh = (await again.svc.identity(create: true))!;
      expect(fresh.deviceId, isNot(before.deviceId));
    });

    test('never overwrites an identity that is already on the phone', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install first, LocalIdentity a) = await registered(phone);
      // Another, valid copy for the same account appears (e.g. a second install raced); the live key stays.
      final Install other = Install(server, uA, MemoryPlatformKeyStore());
      final LocalIdentity b = (await other.svc.identity(create: true))!;
      final Install sameInstall = Install(server, uA, phone);
      for (final String n in <String>['identity_seed', 'device_id', 'identity_user']) {
        await sameInstall.vault.write(n, (await first.vault.read(n))!);
      }
      await phone.write(await KeyBackup.entryKey(uA),
          await KeyBackup.seal(BackedUpIdentity(uA, b.deviceId, E2ee.randomBytes(32)), phone.secret));
      final LocalIdentity live = (await sameInstall.svc.identity())!;
      expect(live.deviceId, a.deviceId);
      expect(sameInstall.restoredDevices, isEmpty);
      expect(sameInstall.api.myKeysCalls, 0, reason: 'a live identity never even looks at the copy');
    });

    test('store failures never throw into sign-in or key creation', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore()..failAll = true;
      final Install i = Install(server, uA, phone);
      expect(await i.svc.identity(), isNull);
      final DeviceKey k = await i.svc.registerThisDevice(label: 'This phone');
      expect(k.isActive, isTrue);
      await i.svc.keyBackupSync;
      expect(phone.data, isEmpty);
    });

    test('a channel without the native side (MissingPluginException) is a miss, not an error', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final KeyBackup kb = KeyBackup(store: const BlockStoreKeyStore(), prefs: MemoryKeyBackupPrefs());
      expect(await kb.load(uA), isNull);
      expect(kb.lastMiss, KeyBackupMiss.storeError);
      expect(await kb.save(BackedUpIdentity(uA, 'd', E2ee.randomBytes(32))), isFalse);
      expect(await kb.removeAll(), isFalse);
    });

    test('offline with a copy present: no new identity is made over it, the next try restores', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity before) = await registered(phone);
      final Install again = Install(server, uA, phone);
      again.api.offline = true;
      expect(await again.svc.identity(), isNull);
      await expectLater(again.svc.identity(create: true), throwsA(isA<StateError>()));
      expect(await again.svc.hasIdentity(), isFalse);
      again.api.offline = false;
      expect((await again.svc.identity(create: true))!.deviceId, before.deviceId);
    });

    test('without a key backup (background isolate) nothing is looked up', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      await registered(phone);
      final Install bg = Install(server, uA, phone, withBackup: false);
      expect(await bg.svc.identity(), isNull);
      expect(bg.api.myKeysCalls, 0);
    });
  });

  group('switch, reset and erase', () {
    test('turning the switch off removes the copy, and nothing is saved or restored while off', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install first, LocalIdentity _) = await registered(phone);
      expect(phone.data, isNotEmpty);
      expect(await first.backup!.setEnabled(false), isTrue);
      expect(phone.data, isEmpty);
      await first.svc.backUpIdentityNow();
      expect(phone.data, isEmpty);
      // Turning it back on saves the live key again.
      await first.backup!.setEnabled(true);
      await first.svc.backUpIdentityNow();
      expect(phone.data, hasLength(1));
    });

    test('an off switch whose delete failed is paid at the next start', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install first, LocalIdentity _) = await registered(phone);
      phone.failAll = true;
      expect(await first.backup!.setEnabled(false), isFalse);
      phone.failAll = false;
      expect(phone.data, isNotEmpty);
      final Install next = Install(server, uA, phone, prefs: first.prefs);
      for (final String n in <String>['identity_seed', 'device_id', 'identity_user']) {
        await next.vault.write(n, (await first.vault.read(n))!);
      }
      await next.svc.identity();
      await next.svc.keyBackupSync;
      expect(phone.data, isEmpty);
    });

    test('erasing the keys removes the copy, so a reinstall cannot bring them back', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install first, LocalIdentity _) = await registered(phone);
      await first.svc.eraseLocalKeys();
      expect(phone.data, isEmpty);
      expect(await first.svc.identity(), isNull);
      final Install again = Install(server, uA, phone);
      expect(await again.svc.identity(), isNull);
    });

    test('erasing the keys removes only the copy of the account that owned them', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install first, LocalIdentity _) = await registered(phone);
      final Install bob = Install(server, uB, phone);
      await bob.svc.identity(create: true);
      expect(phone.data, hasLength(2));
      await first.svc.eraseLocalKeys();
      expect(phone.data.keys, <String>[await KeyBackup.entryKey(uB)]);
    });

    test('a reset leaves the copy holding exactly the key that stays', () async {
      final MemoryPlatformKeyStore phone = MemoryPlatformKeyStore();
      final (Install _, LocalIdentity old) = await registered(phone);
      // This phone's key is lost (not via the app): a new install without the copy resets the account.
      final Install reset = Install(server, uA, MemoryPlatformKeyStore());
      final KeyResetResult r = await reset.svc.resetThisDevice();
      expect(r.key.deviceId, isNot(old.deviceId));
      // The old phone's copy is now of a revoked key: a reinstall there refuses it.
      final Install oldAgain = Install(server, uA, phone);
      expect(await oldAgain.svc.identity(), isNull);
      // The resetting phone's copy is its new key and restores after its own reinstall.
      final Install resetAgain = Install(server, uA, reset.store);
      expect((await resetAgain.svc.identity())!.deviceId, r.key.deviceId);
    });

    test('Block Store channel contract: method names and arguments', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel ch = MethodChannel('app.openfamily/key_backup');
      final Map<String, Uint8List> mem = <String, Uint8List>{};
      final List<String> calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (MethodCall c) async {
        calls.add(c.method);
        final Map<dynamic, dynamic>? a = c.arguments as Map<dynamic, dynamic>?;
        switch (c.method) {
          case 'store':
            mem[a!['key'] as String] = a['bytes'] as Uint8List;
            return true;
          case 'retrieve':
            return mem[a!['key'] as String];
          case 'delete':
            mem.remove(a!['key'] as String);
            return null;
          case 'deleteAll':
            mem.clear();
            return null;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));
      final KeyBackup kb = KeyBackup(store: const BlockStoreKeyStore(), prefs: MemoryKeyBackupPrefs());
      final Uint8List seed = E2ee.randomBytes(32);
      expect(await kb.save(BackedUpIdentity(uA, 'dev', seed)), isTrue);
      expect(E2ee.hex((await kb.load(uA))!.seed), E2ee.hex(seed));
      expect(await kb.remove(uA), isTrue);
      expect(await kb.load(uA), isNull);
      expect(await kb.setEnabled(false), isTrue);
      expect(calls, containsAll(<String>['store', 'retrieve', 'delete', 'deleteAll']));
    });
  });
}
