// Production report (v0.26.31, Android): the Encryption keys screen said "The key is stored, but the note of this phone's
// id that belongs to it is damaged. (Reason: device-id-format.)". The vault entry `device_id` was present but not valid
// UTF-8 (a device id is a UUID string, which always is), while the seed was stored. Nobody knows how the entry got those
// bytes; the repair does not need to.
//
// These tests pin the repair: the id is written again ONLY from the server's active `device` key of the signed-in
// account whose public keys are exactly the ones the stored seed derives; the seed is never written, never wiped; a
// vault read failure, a wrong seed size, a key the server does not vouch for, two candidates, another account, an
// erase in the middle, and a healthy phone all end with nothing written.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/encryption_keys_screen.dart';
import 'package:openfamily/services/diagnostics/diagnostics_probe.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/storage_event_log.dart';
import 'package:openfamily/services/storage_self_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_e2ee_server.dart';
import 'owner_note_repair_test.dart' show FlakyApi, GatedApi, OrderVault, PickyVault, snapshot, svcOn, until;
import 'private_runtime_test.dart' show priv, uA, uB;

/// A server that lists exactly [listed] (instead of what is registered), counting how often it was asked.
class ListedApi extends FlakyApi {
  ListedApi(super.server, super.uid, this.listed);
  List<DeviceKey> listed;
  int asked = 0;

  @override
  Future<List<DeviceKey>> myKeys() async {
    asked++;
    if (!online) throw StateError('offline');
    return List<DeviceKey>.of(listed);
  }
}

/// Counts the questions to the server, answering from what is registered.
class CountingApi extends FlakyApi {
  CountingApi(super.server, super.uid);
  int asked = 0;

  @override
  Future<List<DeviceKey>> myKeys() async {
    asked++;
    return super.myKeys();
  }
}

DeviceKey copyKey(DeviceKey k, {String? deviceId, String? userId, String? kind, Uint8List? edPub, Uint8List? xPub, bool? revoked}) => DeviceKey(
      deviceId: deviceId ?? k.deviceId,
      userId: userId ?? k.userId,
      kind: kind ?? k.kind,
      edPub: edPub ?? k.edPub,
      xPub: xPub ?? k.xPub,
      fingerprint: k.fingerprint,
      digits: k.digits,
      short: k.short,
      registeredByDeviceId: k.registeredByDeviceId,
      registeredByPub: k.registeredByPub,
      registrationAction: k.registrationAction,
      registrationSignature: k.registrationSignature,
      initial: k.initial,
      label: k.label,
      createdAt: k.createdAt,
      revokedAt: revoked == true ? DateTime.now().toUtc() : k.revokedAt,
      caps: k.caps,
    );

/// 32 bytes that are not valid UTF-8 (the first byte is a continuation byte), like the damaged entry of the report.
Uint8List garbage() => Uint8List.fromList(List<int>.generate(32, (int i) => 0x80 + i));

void main() {
  late FakeE2eeServer server;
  void resetServer() {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(priv, members: <String>[uA, uB], admin: uA);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    resetServer();
  });

  Future<List<String>> events() => StorageEventLog.instance.events();

  /// The phone of the report: a registered key; then the `device_id` entry is replaced by [damage].
  Future<(T, Map<String, List<int>>, String)> phone<T extends MemoryVault>(T v, {Uint8List? damage, bool removeId = false}) async {
    await svcOn(server, uA, v).registerThisDevice();
    final String serverId = utf8.decode(v.data['device_id']!);
    if (removeId) {
      v.data.remove('device_id');
    } else {
      v.data['device_id'] = damage ?? garbage();
    }
    return (v, snapshot(v), serverId);
  }

  /// Nothing but (at most) the device id was written: the seed and the account note are byte for byte as before and
  /// nothing was put aside.
  void expectSeedUntouched(MemoryVault v, Map<String, List<int>> before) {
    expect(v.data['identity_seed'], before['identity_seed'], reason: 'the seed is never changed');
    expect(v.data['identity_user'], before['identity_user'], reason: 'the account note is not changed by this repair');
    expect(v.archived, isEmpty, reason: 'nothing was put aside or wiped');
  }

  Future<LocalKeyException> failure(E2eeService s) => s.identity().then<LocalKeyException>((_) => fail('should not open'), onError: (Object x) => x as LocalKeyException);

  void expectNoKeyBytesInEvents(List<String> lines, Iterable<Uint8List> secrets) {
    for (final String l in lines) {
      for (final Uint8List b in secrets) {
        expect(l.contains(E2ee.hex(b)), isFalse, reason: l);
        expect(l.contains(base64.encode(b)), isFalse, reason: l);
        expect(l.contains(E2ee.b64(b)), isFalse, reason: l);
      }
    }
  }

  group('the exact state of the report', () {
    test('seed stored, device_id = 32 non-UTF-8 bytes, owner note ok, server lists exactly that key: identity() opens it with the server\'s id', () async {
      final (MemoryVault v, Map<String, List<int>> before, String serverId) = await phone(MemoryVault());
      expect(before['identity_user'], isNotNull);
      final CountingApi api = CountingApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);

      final LocalIdentity id = (await svc.identity())!;
      expect(id.deviceId, serverId);
      expect(id.userId, uA);
      expect(utf8.decode(v.data['device_id']!), serverId, reason: 'only the device id entry was written, with the server\'s id');
      expectSeedUntouched(v, before);
      expect(api.asked, 1);

      final List<String> ev = await events();
      expect(ev.any((String l) => l.contains('device_id_damaged') && l.contains('was=garbled len=32 equals_seed=false equals_owner=false all_zero=false')), isTrue);
      expect(ev.any((String l) => l.contains('device_id_repaired') && l.contains('was=garbled len=32 equals_seed=false')), isTrue);
      expectNoKeyBytesInEvents(ev, <Uint8List>[garbage(), Uint8List.fromList(before['identity_seed']!)]);

      // The next start reads the repaired entry like any healthy phone: no network call.
      final CountingApi api2 = CountingApi(server, uA);
      expect((await svcOn(server, uA, v, api: api2).identity())!.deviceId, serverId);
      expect(api2.asked, 0);
    });

    test('the Encryption keys self-check and the Diagnostics key check pass after the repair', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault());
      Future<String> check() => StorageSelfCheck.run(readTokens: () async => const [], readErrors: () => const <String, String>{}, vault: v);
      expect(await check(), contains('identity=bad(device_format)'), reason: 'read-only: it only reports');
      expect((await DiagnosticsProbe.checkKeyUsable(svcOn(server, uA, v))).ok, isTrue);
      expect(await check(), contains('identity=ok'));
    });

    test('the device id missing entirely is repaired the same way', () async {
      final (MemoryVault v, Map<String, List<int>> before, String serverId) = await phone(MemoryVault(), removeId: true);
      final LocalIdentity id = (await svcOn(server, uA, v).identity())!;
      expect(id.deviceId, serverId);
      expect(utf8.decode(v.data['device_id']!), serverId);
      expectSeedUntouched(v, before);
      final List<String> ev = await events();
      expect(ev.any((String l) => l.contains('device_id_repaired') && l.contains('was=missing len=0 equals_seed=false')), isTrue);
    });

    test('an empty device id is repaired as missing', () async {
      final (MemoryVault v, Map<String, List<int>> before, String serverId) = await phone(MemoryVault(), damage: Uint8List(0));
      expect((await svcOn(server, uA, v).identity())!.deviceId, serverId);
      expectSeedUntouched(v, before);
    });

    test('a device id equal to the seed bytes: the event says equals_seed=true and never contains the bytes', () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      final Uint8List seed = Uint8List.fromList(v.data['identity_seed']!);
      final String serverId = utf8.decode(v.data['device_id']!);
      v.data['device_id'] = Uint8List.fromList(seed);
      final Map<String, List<int>> before = snapshot(v);
      expect((await svcOn(server, uA, v).identity())!.deviceId, serverId);
      expectSeedUntouched(v, before);
      final List<String> ev = await events();
      expect(ev.any((String l) => l.contains('device_id_damaged') && l.contains('len=32 equals_seed=true')), isTrue);
      expect(ev.any((String l) => l.contains('device_id_repaired') && l.contains('equals_seed=true')), isTrue);
      expectNoKeyBytesInEvents(ev, <Uint8List>[seed]);
    });

    test('forensics: a device id equal to the owner note bytes, and an all-zero one, are told apart', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault(), damage: Uint8List.fromList(<int>[0xff, 0xfe]));
      v.data['identity_user'] = Uint8List.fromList(<int>[0xff, 0xfe]); // garbled owner note too; the device id is repaired first
      v.data['device_id'] = Uint8List.fromList(<int>[0xff, 0xfe]);
      final E2eeService svc = svcOn(server, uA, v);
      expect(await svc.repairDeviceId(), DeviceRepair.repaired);
      expect((await events()).any((String l) => l.contains('len=2 equals_seed=false equals_owner=true all_zero=false')), isTrue);

      resetServer();
      final (MemoryVault z, _, _) = await phone(MemoryVault(), damage: Uint8List(32));
      expect(await svcOn(server, uA, z).repairDeviceId(), DeviceRepair.repaired);
      expect((await events()).any((String l) => l.contains('len=32 equals_seed=false equals_owner=false all_zero=true')), isTrue);
    });

    test('a damaged device id AND a damaged account note: the id first, then the existing owner repair; both without a reset', () async {
      final (MemoryVault v, Map<String, List<int>> before, String serverId) = await phone(MemoryVault());
      v.data['identity_user'] = Uint8List.fromList(<int>[0xff, 0xfe, 0xfd]);
      final LocalIdentity id = (await svcOn(server, uA, v).identity())!;
      expect(id.deviceId, serverId);
      expect(utf8.decode(v.data['device_id']!), serverId);
      expect(utf8.decode(v.data['identity_user']!), uA);
      expect(v.data['identity_seed'], before['identity_seed']);
      expect(v.archived, isEmpty);
    });

    test('a device id that is readable text but not a UUID is NOT touched (only unreadable or missing ids are repaired)', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault(), damage: Uint8List.fromList(utf8.encode('not-a-uuid')));
      final Map<String, List<int>> before = snapshot(v);
      final CountingApi api = CountingApi(server, uA);
      expect((await svcOn(server, uA, v, api: api).identity())!.deviceId, 'not-a-uuid');
      expect(snapshot(v), before);
      expect(api.asked, 0);
    });
  });

  group('refused: nothing is written, the reason is named', () {
    void expectUntouched(MemoryVault v, Map<String, List<int>> before) {
      expect(snapshot(v), before, reason: 'the vault is byte for byte as it was');
      expect(v.archived, isEmpty);
    }

    test('(d) the server lists no matching key: nothing written, the reason code says why, the way out is named', () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).identity(create: true); // never registered
      v.data['device_id'] = garbage();
      final Map<String, List<int>> before = snapshot(v);
      final E2eeService svc = svcOn(server, uA, v);
      final LocalKeyException e = await failure(svc);
      expect(e.cause, KeyCause.deviceIdFormat);
      expect(e.reasonCode, 'device-id-format');
      expect(e.repair, 'notOurs');
      expect(e.deviceIdRepairable, isTrue);
      expect(e.keyIntact, isTrue);
      expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
      expectUntouched(v, before);
      final List<String> ev = await events();
      expect(ev.any((String l) => l.contains('identity_unreadable') && l.contains('cause=device-id-format') && l.contains('repair=notOurs')), isTrue);
      expect(ev.any((String l) => l.contains('device_id_repair_refused') && l.contains('reason=unknown')), isTrue);
    });

    test('(e) the matching key is revoked', () async {
      final (MemoryVault v, Map<String, List<int>> before, String serverId) = await phone(MemoryVault());
      await server.client(uA).revoke(serverId, <String, dynamic>{});
      final E2eeService svc = svcOn(server, uA, v);
      expect((await failure(svc)).repair, 'notOurs');
      expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
      expectUntouched(v, before);
      expect((await events()).any((String l) => l.contains('device_id_repair_refused') && l.contains('reason=revoked')), isTrue);
    });

    test('(f) two matching keys: ambiguous, nothing written', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final DeviceKey k = server.keys[uA]!.single;
      final ListedApi api = ListedApi(server, uA, <DeviceKey>[k, copyKey(k, deviceId: 'a-second-id-for-the-same-keys')]);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final LocalKeyException e = await failure(svc);
      expect(e.repair, 'ambiguous');
      expect(await svc.repairDeviceId(), DeviceRepair.ambiguous);
      expectUntouched(v, before);
      expect((await events()).any((String l) => l.contains('device_id_repair_refused') && l.contains('reason=ambiguous')), isTrue);
    });

    test('(g) a key with different public keys (even if its id is the one this phone had): refused', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final DeviceKey k = server.keys[uA]!.single;
      final Uint8List flipped = Uint8List.fromList(k.edPub)..[0] ^= 0x01;
      for (final DeviceKey other in <DeviceKey>[
        copyKey(k, edPub: flipped),
        copyKey(k, xPub: Uint8List.fromList(k.xPub)..[0] ^= 0x01),
      ]) {
        final E2eeService svc = svcOn(server, uA, v, api: ListedApi(server, uA, <DeviceKey>[other]));
        expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
        expectUntouched(v, before);
      }
    });

    test('(g2) a matching key of a kind other than device (recovery) is refused', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final DeviceKey k = server.keys[uA]!.single;
      final E2eeService svc = svcOn(server, uA, v, api: ListedApi(server, uA, <DeviceKey>[copyKey(k, kind: 'recovery')]));
      expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
      expectUntouched(v, before);
    });

    test('(g3) the same public keys but a fingerprint that is not theirs: refused', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final DeviceKey k = server.keys[uA]!.single;
      final DeviceKey wrong = DeviceKey(
        deviceId: k.deviceId, userId: k.userId, kind: k.kind, edPub: k.edPub, xPub: k.xPub, fingerprint: '00' * 32, digits: k.digits,
        short: k.short, registeredByDeviceId: k.registeredByDeviceId, registeredByPub: k.registeredByPub,
        registrationAction: k.registrationAction, registrationSignature: k.registrationSignature, initial: k.initial,
        label: k.label, createdAt: k.createdAt, caps: k.caps);
      final E2eeService svc = svcOn(server, uA, v, api: ListedApi(server, uA, <DeviceKey>[wrong]));
      expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
      expectUntouched(v, before);
      expect((await events()).any((String l) => l.contains('device_id_repair_refused') && l.contains('reason=mismatch')), isTrue);
    });

    test("(h) another account's key with the same public keys is refused", () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final DeviceKey k = server.keys[uA]!.single;
      final E2eeService svc = svcOn(server, uA, v, api: ListedApi(server, uA, <DeviceKey>[copyKey(k, userId: uB)]));
      expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
      expect((await failure(svc)).repair, 'notOurs');
      expectUntouched(v, before);
      expect((await events()).any((String l) => l.contains('device_id_repair_refused') && l.contains('reason=kind')), isTrue);
    });

    test('(i) the account note names another account: never adopted, never repaired; the old put-aside behaviour is unchanged', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final CountingApi api = CountingApi(server, uB);
      final E2eeService asB = svcOn(server, uB, v, api: api);
      expect(await asB.repairDeviceId(), DeviceRepair.otherAccount);
      expect(api.asked, 0, reason: 'refused before the server is asked');
      expectUntouched(v, before);
      expect((await events()).any((String l) => l.contains('device_id_repair_refused') && l.contains('reason=other-account')), isTrue);

      // identity() as the other account puts A's key aside intact; it never writes a device id for B next to A's seed.
      expect(await asB.identity(), isNull);
      expect(v.archived.values.single['identity_seed'], before['identity_seed']);
      expect(v.archived.values.single['device_id'], before['device_id'], reason: 'the damaged note is put aside as it was');
      expect(v.data.containsKey('device_id'), isFalse);
      expect(v.data.containsKey('identity_seed'), isFalse);
    });

    test('(k) a seed of the wrong length is never repaired and the server is not asked', () async {
      for (final int len in <int>[31, 33, 0]) {
        resetServer();
        final (MemoryVault v, _, _) = await phone(MemoryVault());
        v.data['identity_seed'] = Uint8List(len);
        final Map<String, List<int>> before = snapshot(v);
        final CountingApi api = CountingApi(server, uA);
        final E2eeService svc = svcOn(server, uA, v, api: api);
        final LocalKeyException e = await failure(svc);
        expect(e.cause, KeyCause.deviceIdFormat, reason: 'len=$len');
        expect(e.repair, 'noKey');
        expect(await svc.repairDeviceId(), DeviceRepair.noKey);
        expect(api.asked, 0);
        expectUntouched(v, before);
      }
    });

    test('no seed at all: nothing to repair, nothing written', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault());
      v.data.remove('identity_seed');
      final Map<String, List<int>> before = snapshot(v);
      final CountingApi api = CountingApi(server, uA);
      expect(await svcOn(server, uA, v, api: api).repairDeviceId(), DeviceRepair.noKey);
      expect(api.asked, 0);
      expect(snapshot(v), before);
    });

    test('no signed-in account: nothing is written', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final E2eeService svc = svcOn(server, uA, v, uid: () async => '');
      expect(await svc.repairDeviceId(), DeviceRepair.noAccount);
      expectUntouched(v, before);
    });

    test('(l) a vault read failure is never repaired, whichever entry fails', () async {
      for (final String failing in <String>['identity_seed', 'device_id', 'identity_user']) {
        resetServer();
        final (PickyVault v, Map<String, List<int>> before, _) = await phone(PickyVault());
        v.failNames.add(failing);
        final CountingApi api = CountingApi(server, uA);
        final E2eeService svc = svcOn(server, uA, v, api: api);
        final LocalKeyException e = await failure(svc);
        expect(e.which, isNotEmpty, reason: failing);
        expect(e.repair, '', reason: 'no repair was attempted: $failing');
        await expectLater(svc.repairDeviceId(), throwsA(isA<LocalKeyException>()), reason: failing);
        expect(api.asked, 0, reason: failing);
        expectUntouched(v, before);
        // The read works again: now it is repaired.
        v.failNames.clear();
        expect(await svc.repairDeviceId(), DeviceRepair.repaired, reason: failing);
      }
    });
  });

  group('offline, and the schedule of retries', () {
    test('(j) offline: nothing written; not asked again within a minute, asked again after it', () async {
      final (MemoryVault v, Map<String, List<int>> before, String serverId) = await phone(MemoryVault());
      final ListedApi api = ListedApi(server, uA, server.keys[uA]!.toList())..online = false;
      DateTime now = DateTime.utc(2026, 11, 10, 16);
      final E2eeService svc = svcOn(server, uA, v, api: api)..ownerClock = () => now;

      final LocalKeyException e = await failure(svc);
      expect(e.repair, 'offline');
      expect(e.cause, KeyCause.deviceIdFormat);
      expect(api.asked, 1);
      expect(snapshot(v), before);

      api.online = true;
      now = now.add(const Duration(seconds: 30));
      expect((await failure(svc)).repair, 'offline', reason: 'within a minute: not asked again');
      expect(api.asked, 1);
      expect(snapshot(v), before);

      now = now.add(const Duration(seconds: 31));
      expect((await svc.identity())!.deviceId, serverId);
      expect(api.asked, 2);
      expect(utf8.decode(v.data['device_id']!), serverId);
      expectSeedUntouched(v, before);
    });

    test('"not ours" is asked again only after 15 minutes; Try again (forgetRepairThrottle) and Repair ask at once', () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).identity(create: true);
      v.data['device_id'] = garbage();
      final ListedApi api = ListedApi(server, uA, <DeviceKey>[]);
      DateTime now = DateTime.utc(2026, 11, 10, 16);
      final E2eeService svc = svcOn(server, uA, v, api: api)..ownerClock = () => now;
      expect((await failure(svc)).repair, 'notOurs');
      now = now.add(const Duration(minutes: 5));
      expect((await failure(svc)).repair, 'notOurs');
      expect(api.asked, 1);
      svc.forgetRepairThrottle();
      expect((await failure(svc)).repair, 'notOurs');
      expect(api.asked, 2);
      expect(await svc.repairDeviceId(), DeviceRepair.notOurs);
      expect(api.asked, 3, reason: 'an explicit Repair always asks');
      now = now.add(const Duration(minutes: 16));
      expect((await failure(svc)).repair, 'notOurs');
      expect(api.asked, 4);
    });

    test('a server that throws is "offline", not a crash', () async {
      final (MemoryVault v, Map<String, List<int>> before, _) = await phone(MemoryVault());
      final E2eeService svc = svcOn(server, uA, v, api: (FlakyApi(server, uA))..online = false);
      expect(await svc.repairDeviceId(), DeviceRepair.offline);
      expect(snapshot(v), before);
    });
  });

  group('erase or restore while the server is asked, and concurrent callers', () {
    test('(m) the keys are erased during the round trip: nothing is written next to no key', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault());
      final GatedApi api = GatedApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final Future<DeviceRepair> r = svc.repairDeviceId();
      await until(() => api.asked == 1);
      expect(await svc.eraseLocalKeys(), isTrue);
      final Map<String, List<int>> afterErase = snapshot(v);
      api.gate.complete();
      expect(await r, DeviceRepair.noKey);
      expect(snapshot(v), afterErase);
      expect(v.data.containsKey('device_id'), isFalse, reason: 'no id next to no key');
      expect(v.data.containsKey('identity_seed'), isFalse);
    });

    test('(m1) erased and the same key put back during the round trip: the repair does not act on what it saw before', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault());
      final GatedApi api = GatedApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final Future<DeviceRepair> r = svc.repairDeviceId();
      await until(() => api.asked == 1);
      expect(await svc.eraseLocalKeys(), isTrue);
      final VaultArchiveSet set = (await (svc.vault.inner as VaultArchive).archives()).single;
      expect(await svc.restoreArchivedIdentity(set), greaterThan(0));
      final Map<String, List<int>> mid = snapshot(v);
      api.gate.complete();
      expect(await r, DeviceRepair.noKey);
      expect(snapshot(v), mid, reason: 'what the restore put back is left as the restore wrote it');
    });

    test('(m2) a different key is restored during the round trip: the id of the old key is not written next to it', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault());
      final GatedApi api = GatedApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final Future<DeviceRepair> r = svc.repairDeviceId();
      await until(() => api.asked == 1);
      v.data['identity_seed'] = Uint8List.fromList(List<int>.generate(32, (int i) => i + 1)); // another seed arrived
      final Map<String, List<int>> mid = snapshot(v);
      api.gate.complete();
      expect(await r, DeviceRepair.noKey);
      expect(snapshot(v), mid);
    });

    test('(m3) somebody else repaired it while the server was asked: nothing is written over theirs', () async {
      final (MemoryVault v, _, serverId) = await phone(MemoryVault());
      final GatedApi api = GatedApi(server, uA);
      final OrderVault ov = OrderVault();
      ov.data.addAll(v.data);
      final E2eeService svc = svcOn(server, uA, ov, api: api);
      final Future<DeviceRepair> r = svc.repairDeviceId();
      await until(() => api.asked == 1);
      ov.data['device_id'] = Uint8List.fromList(utf8.encode(serverId));
      api.gate.complete();
      expect(await r, DeviceRepair.notNeeded);
      expect(ov.writes, isEmpty);
    });

    test('(m4) the account is replaced during the round trip: not written', () async {
      final (MemoryVault v, _, _) = await phone(MemoryVault());
      final GatedApi api = GatedApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final Future<DeviceRepair> r = svc.repairDeviceId();
      await until(() => api.asked == 1);
      v.data['identity_user'] = Uint8List.fromList(utf8.encode(uB));
      final Map<String, List<int>> mid = snapshot(v);
      api.gate.complete();
      expect(await r, DeviceRepair.otherAccount);
      expect(snapshot(v), mid);
    });

    test('(n) two concurrent identity() calls share one repair: one question to the server, one write', () async {
      final (MemoryVault base, _, serverId) = await phone(MemoryVault());
      final OrderVault v = OrderVault()..data.addAll(base.data);
      final GatedApi api = GatedApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final Future<LocalIdentity?> a = svc.identity();
      final Future<LocalIdentity?> b = svc.identity();
      await until(() => api.asked >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      api.gate.complete();
      expect((await a)!.deviceId, serverId);
      expect((await b)!.deviceId, serverId);
      expect(api.asked, 1);
      expect(v.writes.where((String n) => n == 'device_id').length, 1);
      expect(v.writes.where((String n) => n == 'identity_seed'), isEmpty);
      expect(v.archived, isEmpty);
    });

    test('(n2) an explicit Repair and identity() at the same time share the same repair', () async {
      final (MemoryVault base, _, serverId) = await phone(MemoryVault());
      final OrderVault v = OrderVault()..data.addAll(base.data);
      final GatedApi api = GatedApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      final Future<LocalIdentity?> a = svc.identity();
      await until(() => api.asked == 1);
      final Future<DeviceRepair> b = svc.repairDeviceId();
      api.gate.complete();
      expect((await a)!.deviceId, serverId);
      expect(await b, DeviceRepair.repaired);
      expect(api.asked, 1);
      expect(v.writes.where((String n) => n == 'device_id').length, 1);
    });
  });

  group('(o) a healthy phone does nothing', () {
    test('no network call and no write; repairDeviceId says notNeeded', () async {
      final OrderVault v = OrderVault();
      await svcOn(server, uA, v).registerThisDevice();
      final Map<String, List<int>> before = snapshot(v);
      v.writes.clear();
      final CountingApi api = CountingApi(server, uA);
      final E2eeService svc = svcOn(server, uA, v, api: api);
      expect((await svc.identity())!.userId, uA);
      expect(await svc.repairDeviceId(), DeviceRepair.notNeeded);
      expect(api.asked, 0);
      expect(v.writes, isEmpty);
      expect(snapshot(v), before);
      final List<String> ev = await events();
      expect(ev.any((String l) => l.contains('device_id_')), isFalse);
    });
  });

  group('the Encryption keys screen', () {
    Future<void> bigView(WidgetTester t) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
    }

    testWidgets('offline: names the problem, offers Repair; Repair writes only after the server answers; the screen then loads', (WidgetTester t) async {
      await bigView(t);
      final (MemoryVault v, Map<String, List<int>> before, serverId) = await phone(MemoryVault());
      final FlakyApi api = FlakyApi(server, uA)..online = false;
      final E2eeService svc = svcOn(server, uA, v, api: api);

      await t.pumpWidget(MaterialApp(home: EncryptionKeysScreen(service: svc)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-title')), findsOneWidget);
      expect(find.textContaining('(Reason: device-id-format.)'), findsOneWidget);
      expect(find.textContaining('Nothing was changed'), findsOneWidget);
      expect(find.textContaining('Open Encryption keys'), findsNothing);
      expect(find.byKey(const Key('keys-repair-device')), findsOneWidget);
      expect(find.byKey(const Key('keys-repair-owner')), findsNothing);
      expect(find.byKey(const Key('keys-repair-note')), findsOneWidget, reason: 'the first look already says the server could not be asked');
      expect(v.data['device_id'], before['device_id']);

      await t.tap(find.byKey(const Key('keys-repair-device')));
      await t.pumpAndSettle();
      expect(find.textContaining('server could not be asked'), findsOneWidget);
      expect(v.data['device_id'], before['device_id']);

      // Back online: Repair writes the server's id and the screen loads normally.
      api.online = true;
      await t.tap(find.byKey(const Key('keys-repair-device')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-title')), findsNothing);
      expect(utf8.decode(v.data['device_id']!), serverId);
      expectSeedUntouched(v, before);
    });

    testWidgets('Try again also reruns the repair', (WidgetTester t) async {
      await bigView(t);
      final (MemoryVault v, Map<String, List<int>> before, serverId) = await phone(MemoryVault());
      final FlakyApi api = FlakyApi(server, uA)..online = false;
      final E2eeService svc = svcOn(server, uA, v, api: api);
      await t.pumpWidget(MaterialApp(home: EncryptionKeysScreen(service: svc)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-title')), findsOneWidget);

      api.online = true; // within a minute of the failed attempt: Try again still asks
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-title')), findsNothing);
      expect(utf8.decode(v.data['device_id']!), serverId);
      expectSeedUntouched(v, before);
    });

    testWidgets('the server has no record of this key: says so in plain words and names Set this phone up again', (WidgetTester t) async {
      await bigView(t);
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).identity(create: true);
      v.data['device_id'] = garbage();
      final Map<String, List<int>> before = snapshot(v);
      await t.pumpWidget(MaterialApp(home: EncryptionKeysScreen(service: svcOn(server, uA, v))));
      await t.pumpAndSettle();
      expect(find.textContaining('server has no record of this key'), findsOneWidget);
      expect(find.textContaining('Set this phone up again'), findsWidgets);
      expect(find.byKey(const Key('keys-repair-reset')), findsOneWidget);
      await t.tap(find.byKey(const Key('keys-repair-device')));
      await t.pumpAndSettle();
      expect(find.textContaining('server has no record of this key'), findsOneWidget);
      expect(snapshot(v), before);
    });
  });
}
