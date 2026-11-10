// Production report (v0.26.30, Android): the Encryption keys screen said the key "can't be read" and the Private
// circle delivery said flush_unreadable, while the startup self-check said identity=ok. The self-check only looked at
// the seed and the device id; the background isolate also needs the note of WHICH ACCOUNT the key belongs to
// (identity_user), and without it every background flush failed with "empty user id".
//
// These tests pin: the diagnosis (the cause is recorded and shown), the repair (the note is written back only after the
// server confirms this phone's key belongs to the signed-in account), and the guard rails (a seed is never changed,
// deleted, or adopted for another account; a vault read failure is never "repaired").
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/encryption_keys_screen.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/e2ee/e2ee_api.dart' show E2eeApi;
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/private_channel.dart' show MemoryKv;
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/storage_event_log.dart';
import 'package:openfamily/services/storage_self_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_e2ee_server.dart';
import 'private_channel_test.dart' show FakeServer, FakeClock;
import 'private_runtime_test.dart' show circleOf, priv, uA, uB;

/// Fails reads of chosen names the way a Keystore that does not open a blob does.
class PickyVault extends MemoryVault {
  final Set<String> failNames = <String>{};
  @override
  Future<Uint8List?> read(String name) async {
    if (failNames.contains(name) && data.containsKey(name)) throw PlatformException(code: 'keystore', message: 'AEADBadTagException');
    return super.read(name);
  }
}

/// A vault whose writes take a while, so a reader can look in the middle of them.
class SlowVault extends MemoryVault {
  @override
  Future<void> write(String name, Uint8List value) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await super.write(name, value);
  }
}

/// The server answers `myKeys` only while [online].
class FlakyApi extends FakeE2eeClient {
  FlakyApi(super.server, super.uid);
  bool online = true;

  @override
  Future<List<DeviceKey>> myKeys() async {
    if (!online) throw StateError('offline');
    return super.myKeys();
  }
}

E2eeService svcOn(FakeE2eeServer s, String user, E2eeVault v, {Future<String> Function()? uid, E2eeApi? api}) => E2eeService(
    api: api ?? s.client(user), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: uid ?? () async => user);

/// The background isolate's service: no network, the account comes from the vault.
E2eeService backgroundOn(FakeE2eeServer s, E2eeVault v) {
  late final E2eeService svc;
  svc = E2eeService(api: s.client(uA), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: () => svc.storedUserId());
  return svc;
}

Map<String, List<int>> snapshot(MemoryVault v) => <String, List<int>>{for (final MapEntry<String, Uint8List> e in v.data.entries) e.key: List<int>.of(e.value)};

void main() {
  late FakeE2eeServer server;
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(priv, members: <String>[uA, uB], admin: uA);
  });

  Future<List<String>> events() => StorageEventLog.instance.events();

  /// The phone of the report: a registered key, then the account note is gone.
  Future<(MemoryVault, Map<String, List<int>>)> phoneWithoutOwnerNote() async {
    final MemoryVault v = MemoryVault();
    await svcOn(server, uA, v).registerThisDevice();
    v.data.remove('identity_user');
    return (v, snapshot(v));
  }

  void expectKeyUntouched(MemoryVault v, Map<String, List<int>> before) {
    expect(v.data['identity_seed'], before['identity_seed'], reason: 'the seed is never changed');
    expect(v.data['device_id'], before['device_id'], reason: 'the device id is never changed');
    expect(v.archived, isEmpty, reason: 'nothing was put aside or wiped');
  }

  group('the exact stored state of the report: seed and device id fine, account note missing', () {
    test('the background isolate cannot use the key and says why; the foreground repairs the note; then both work', () async {
      final (MemoryVault v, Map<String, List<int>> before) = await phoneWithoutOwnerNote();

      final E2eeService bg = backgroundOn(server, v);
      final LocalKeyException e = await bg.identity().then<LocalKeyException>((_) => fail('should not open'), onError: (Object x) => x as LocalKeyException);
      expect(e.problem, LocalKeyProblem.unreadable);
      expect(e.cause, KeyCause.emptyUserId);
      expect(e.reasonCode, 'empty-user-id');
      expectKeyUntouched(v, before);
      expect((await events()).any((String l) => l.contains('identity_unreadable') && l.contains('cause=empty-user-id') && l.contains('owner=missing')), isTrue);

      // The foreground (uid from the profile) always worked; now it also writes the note back, after asking the server.
      final E2eeService fg = svcOn(server, uA, v);
      final LocalIdentity id = (await fg.identity())!;
      expect(utf8.decode(v.data['identity_user']!), uA);
      expectKeyUntouched(v, before);
      expect((await events()).any((String l) => l.contains('owner_repaired')), isTrue);

      // The background isolate's next run opens the very same key.
      final LocalIdentity bgId = (await backgroundOn(server, v).identity())!;
      expect(bgId.deviceId, id.deviceId);
      expect(bgId.userId, uA);
      expectKeyUntouched(v, before);
    });

    test('the flush says why: flush_unreadable:empty-user-id, with words for it in the report', () async {
      final (MemoryVault v, _) = await phoneWithoutOwnerNote();
      final E2eeService bg = backgroundOn(server, v);
      final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 10, 16));
      final PrivateRuntime rt = PrivateRuntime(service: bg, api: server.client(uA), kv: MemoryKv(), clock: clock, channel: FakeServer());
      await rt.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      await rt.flush();
      final PrivateDeliveryFacts f = await rt.deliveryFacts();
      expect(f.lastErrorCode, 'flush_unreadable:empty-user-id');
      expect(plainDeliveryProblem(f.lastErrorCode), contains('note of which account'));
      expect(plainDeliveryProblem(f.lastErrorCode), isNot(contains('there was a problem sending')));
    });

    test('an empty note (never "another account") is treated like a missing one: no wipe, repaired', () async {
      final (MemoryVault v, Map<String, List<int>> before) = await phoneWithoutOwnerNote();
      v.data['identity_user'] = Uint8List(0);
      final E2eeService fg = svcOn(server, uA, v);
      expect((await fg.identity())!.userId, uA);
      expect(utf8.decode(v.data['identity_user']!), uA);
      expectKeyUntouched(v, before);
    });

    test('a damaged note is repaired when the server confirms; while it cannot be asked the key is left alone and the cause is named', () async {
      final (MemoryVault v, Map<String, List<int>> before) = await phoneWithoutOwnerNote();
      v.data['identity_user'] = Uint8List.fromList(<int>[0xff, 0xfe, 0xfd]);
      final FlakyApi api = FlakyApi(server, uA)..online = false;
      final E2eeService fg = svcOn(server, uA, v, api: api);
      final LocalKeyException e = await fg.identity().then<LocalKeyException>((_) => fail('should not open'), onError: (Object x) => x as LocalKeyException);
      expect(e.cause, KeyCause.ownerFormat);
      expect(e.ownerRepairable, isTrue);
      expect(e.whatIsWrong, contains('note of which account'));
      expect(v.data['identity_user'], <int>[0xff, 0xfe, 0xfd], reason: 'nothing written without the server');
      expectKeyUntouched(v, before);

      api.online = true;
      expect(await fg.repairOwnerRecord(), OwnerRepair.repaired);
      expect(utf8.decode(v.data['identity_user']!), uA);
      expect((await fg.identity())!.userId, uA);
      expectKeyUntouched(v, before);
    });

    test('server unreachable: the foreground still works as before, nothing is written, the repair is retried later', () async {
      final (MemoryVault v, Map<String, List<int>> before) = await phoneWithoutOwnerNote();
      final FlakyApi api = FlakyApi(server, uA)..online = false;
      final E2eeService fg = svcOn(server, uA, v, api: api);
      expect((await fg.identity())!.userId, uA);
      expect(v.data.containsKey('identity_user'), isFalse);
      expectKeyUntouched(v, before);
      expect(await fg.repairOwnerRecord(), OwnerRepair.offline);
      api.online = true;
      expect(await fg.repairOwnerRecord(), OwnerRepair.repaired);
      expectKeyUntouched(v, before);
    });

    test('the server does not list this key under the account: nothing is written (an unregistered key is not adopted)', () async {
      final MemoryVault v = MemoryVault();
      final E2eeService fg = svcOn(server, uA, v);
      await fg.identity(create: true); // created locally, never registered
      v.data.remove('identity_user');
      final Map<String, List<int>> before = snapshot(v);
      final E2eeService again = svcOn(server, uA, v);
      expect((await again.identity())!.userId, uA);
      expect(v.data.containsKey('identity_user'), isFalse);
      expect(await again.repairOwnerRecord(), OwnerRepair.notOurs);
      expectKeyUntouched(v, before);
      // Registering it (the account now vouches for it) writes the note back.
      await again.registerThisDevice();
      expect(utf8.decode(v.data['identity_user']!), uA);
      expectKeyUntouched(v, before);
    });

    test('the server lists the device id with DIFFERENT public keys, or revoked: nothing is written', () async {
      final MemoryVault other = MemoryVault();
      await svcOn(server, uA, other).registerThisDevice();
      final String otherDevice = utf8.decode(other.data['device_id']!);
      // This phone has its own seed but borrowed the registered device id of another key.
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).identity(create: true);
      v.data['device_id'] = Uint8List.fromList(utf8.encode(otherDevice));
      v.data.remove('identity_user');
      final Map<String, List<int>> before = snapshot(v);
      expect(await svcOn(server, uA, v).repairOwnerRecord(), OwnerRepair.notOurs);
      expect(v.data.containsKey('identity_user'), isFalse);
      expectKeyUntouched(v, before);
    });
  });

  group('near states that must NOT be repaired or adopted', () {
    test("another account's note is never adopted or overwritten: the old behaviour (put aside, not destroyed) is unchanged", () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      final List<int> seed = List<int>.of(v.data['identity_seed']!);
      final E2eeService asB = svcOn(server, uB, v);
      expect(await asB.repairOwnerRecord(), OwnerRepair.otherAccount);
      expect(utf8.decode(v.data['identity_user']!), uA, reason: 'not overwritten');
      expect(await asB.identity(), isNull, reason: 'not adopted: B gets no key from A\'s seed');
      expect(v.archived.values.single['identity_seed'], seed, reason: 'A\'s key is put aside intact, restorable');
      expect(v.data.containsKey('identity_user'), isFalse, reason: 'B\'s id was not written over it');
    });

    test('a seed of the wrong length is reported and never touched, even with the note missing', () async {
      final (MemoryVault v, _) = await phoneWithoutOwnerNote();
      v.data['identity_seed'] = Uint8List(31);
      final Map<String, List<int>> before = snapshot(v);
      final LocalKeyException e = await svcOn(server, uA, v).identity().then<LocalKeyException>((_) => fail('x'), onError: (Object x) => x as LocalKeyException);
      expect(e.cause, KeyCause.seedLength);
      expect(e.keyIntact, isFalse);
      expect(await svcOn(server, uA, v).repairOwnerRecord(), OwnerRepair.noKey);
      expect(snapshot(v), before);
      expect(v.archived, isEmpty);
    });

    test('a vault read failure on the note is never repaired and names which entry failed', () async {
      final PickyVault v = PickyVault();
      await svcOn(server, uA, v).registerThisDevice();
      final Map<String, List<int>> before = snapshot(v);
      v.failNames.add('identity_user');
      final E2eeService fg = svcOn(server, uA, v);
      final LocalKeyException e = await fg.identity().then<LocalKeyException>((_) => fail('x'), onError: (Object x) => x as LocalKeyException);
      expect(e.which, 'owner');
      expect(e.cause, 'PlatformException');
      expect(e.reasonCode, 'owner-read-PlatformException');
      await expectLater(fg.repairOwnerRecord(), throwsA(isA<LocalKeyException>()));
      expect(snapshot(v), before, reason: 'nothing written while a read fails');
      expect((await events()).any((String l) => l.contains('identity_read_failed') && l.contains('which=owner')), isTrue);
      v.failNames.clear();
      expect((await fg.identity())!.userId, uA);
      expect(snapshot(v), before);
    });

    test('a failing read of the seed names the seed', () async {
      final PickyVault v = PickyVault();
      await svcOn(server, uA, v).registerThisDevice();
      v.failNames.add('identity_seed');
      final LocalKeyException e = await svcOn(server, uA, v).identity().then<LocalKeyException>((_) => fail('x'), onError: (Object x) => x as LocalKeyException);
      expect(e.reasonCode, 'seed-read-PlatformException');
      expect(e.whatIsWrong, contains('Nothing was changed'));
    });

    test('a seed without its device id is reported, never "created over", and stays as it is', () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      v.data.remove('device_id');
      final Map<String, List<int>> before = snapshot(v);
      final E2eeService s = svcOn(server, uA, v);
      final LocalKeyException e = await s.identity(create: true).then<LocalKeyException>((_) => fail('x'), onError: (Object x) => x as LocalKeyException);
      expect(e.cause, KeyCause.deviceIdMissing);
      expect(snapshot(v), before);
      expect((await events()).any((String l) => l.contains('identity_partial')), isTrue);
    });
  });

  group('creating an identity while another reader looks', () {
    test('a concurrent reader never sees a seed without its device id; the identity completes', () async {
      final SlowVault v = SlowVault();
      final E2eeService creator = svcOn(server, uA, v);
      final E2eeService reader = svcOn(server, uA, v);
      final Future<LocalIdentity?> made = creator.identity(create: true);
      final List<Object?> seen = <Object?>[];
      for (int i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        try {
          seen.add((await reader.identity())?.deviceId);
        } catch (e) {
          seen.add(e);
        }
      }
      final LocalIdentity id = (await made)!;
      expect(seen.whereType<LocalKeyException>(), isEmpty, reason: 'no half-written read: $seen');
      expect(seen.last, id.deviceId);
      expect((await reader.identity())!.deviceId, id.deviceId);
      expect(utf8.decode(v.data['identity_user']!), uA);
    });

    test('two creators at once end with ONE identity (the second never replaces the first)', () async {
      final SlowVault v = SlowVault();
      final E2eeService a = svcOn(server, uA, v);
      final Future<LocalIdentity?> fa = a.identity(create: true);
      final Future<LocalIdentity?> fb = a.identity(create: true);
      final List<LocalIdentity?> r = await Future.wait(<Future<LocalIdentity?>>[fa, fb]);
      expect(r[0]!.deviceId, r[1]!.deviceId);
      expect(utf8.decode(v.data['device_id']!), r[0]!.deviceId);
    });

    test('a create whose last write fails leaves no seed (the next call creates cleanly), never a seed without a device id', () async {
      final _FailOnSeed v = _FailOnSeed();
      final E2eeService s = svcOn(server, uA, v);
      await expectLater(s.identity(create: true), throwsA(isA<StateError>()));
      expect(v.data.containsKey('identity_seed'), isFalse);
      v.failSeed = false;
      expect((await svcOn(server, uA, v).identity(create: true))!.userId, uA);
    });
  });

  group('the startup self-check reads the account note and the content', () {
    Future<String> check(MemoryVault v) =>
        StorageSelfCheck.run(readTokens: () async => const [], readErrors: () => const <String, String>{}, vault: v);

    test('identity=ok owner=ok | missing | empty | garbled', () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      expect(await check(v), contains('identity=ok owner=ok'));
      v.data.remove('identity_user');
      expect(await check(v), contains('identity=ok owner=missing'));
      v.data['identity_user'] = Uint8List(0);
      expect(await check(v), contains('owner=empty'));
      v.data['identity_user'] = Uint8List.fromList(<int>[0xff, 0xfe]);
      expect(await check(v), contains('owner=garbled'));
    });

    test('a key that opens but is not usable no longer says identity=ok; the check never writes', () async {
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      v.data['identity_seed'] = Uint8List(31);
      final Map<String, List<int>> before = snapshot(v);
      expect(await check(v), contains('identity=bad(seed_len)'));
      v.data['identity_seed'] = Uint8List(32);
      v.data['device_id'] = Uint8List.fromList(<int>[0xff, 0xfe]);
      final Map<String, List<int>> before2 = snapshot(v);
      expect(await check(v), contains('identity=bad(device_format)'));
      expect(snapshot(v), before2);
      expect(before.keys, before2.keys);
    });

    test('a failing note read is reported on its own and the key is still reported', () async {
      final PickyVault v = PickyVault();
      await svcOn(server, uA, v).registerThisDevice();
      v.failNames.add('identity_user');
      expect(await check(v), contains('identity=ok owner=unreadable(PlatformException)'));
    });
  });

  group('wording', () {
    test('message works from anywhere; the screen version does not send the person to the screen they are on', () {
      for (final LocalKeyProblem p in <LocalKeyProblem>[LocalKeyProblem.missing, LocalKeyProblem.unreadable, LocalKeyProblem.invalidated]) {
        final LocalKeyException e = LocalKeyException(p);
        expect(e.message, contains('Open Encryption keys'));
        expect(e.screenMessage, isNot(contains('Open Encryption keys')));
        expect(e.screenMessage, isNotEmpty);
      }
      expect(const LocalKeyException(LocalKeyProblem.locked).screenMessage, const LocalKeyException(LocalKeyProblem.locked).message);
    });
  });

  group('the Encryption keys screen', () {
    testWidgets('names the problem, offers Repair, never says "Open Encryption keys", and Try again re-runs the repair', (WidgetTester t) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      v.data['identity_user'] = Uint8List.fromList(<int>[0xff, 0xfe, 0xfd]);
      final Map<String, List<int>> before = snapshot(v);
      final FlakyApi api = FlakyApi(server, uA)..online = false;
      final E2eeService svc = svcOn(server, uA, v, api: api);

      await t.pumpWidget(MaterialApp(home: EncryptionKeysScreen(service: svc)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-title')), findsOneWidget);
      expect(find.textContaining('lost the note of which account'), findsWidgets);
      expect(find.textContaining('Open Encryption keys'), findsNothing);
      expect(find.byKey(const Key('keys-repair-owner')), findsOneWidget);

      // Repair while the server cannot be asked: says so, changes nothing.
      await t.tap(find.byKey(const Key('keys-repair-owner')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-note')), findsOneWidget);
      expect(v.data['identity_user'], <int>[0xff, 0xfe, 0xfd]);

      // The server is back: "Try again" re-runs the check AND the repair.
      api.online = true;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('keys-repair-title')), findsNothing);
      expect(utf8.decode(v.data['identity_user']!), uA);
      expect(v.data['identity_seed'], before['identity_seed']);
      expect(v.data['device_id'], before['device_id']);
    });

    testWidgets('an unreadable cause that cannot be repaired says what it is and still offers only Try again and set up again', (WidgetTester t) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final MemoryVault v = MemoryVault();
      await svcOn(server, uA, v).registerThisDevice();
      v.data.remove('device_id');
      await t.pumpWidget(MaterialApp(home: EncryptionKeysScreen(service: svcOn(server, uA, v))));
      await t.pumpAndSettle();
      expect(find.textContaining("note of this phone's id"), findsOneWidget);
      expect(find.textContaining('Open Encryption keys'), findsNothing);
      expect(find.byKey(const Key('keys-repair-owner')), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byKey(const Key('keys-repair-reset')), findsOneWidget);
    });
  });
}

class _FailOnSeed extends MemoryVault {
  bool failSeed = true;
  @override
  Future<void> write(String name, Uint8List value) async {
    if (failSeed && name == 'identity_seed') throw StateError('disk full');
    await super.write(name, value);
  }
}
