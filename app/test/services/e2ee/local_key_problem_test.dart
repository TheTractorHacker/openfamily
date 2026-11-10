// Production report (v0.26.0, Android, a Private circle with server processing):
// turning Private OFF said "Can't reach the server" while the server was fine,
// and the owner's own position stopped updating. These tests pin the fixes:
//  * a failure of this phone's own key is reported as such (never as "offline"),
//  * E2eeService never null-checks a missing identity into a TypeError,
//  * a fix that cannot be sealed leaves a reason the Delivery screen shows,
//  * two isolates sealing with the same device never reuse a sequence number.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import 'private_channel_test.dart' show FakeServer, FakeClock, Keys, Phone;
import 'private_runtime_test.dart' show circleOf, priv, uA, uB;

/// A vault whose reads fail the way the Android Keystore channel fails: a
/// PlatformException for a blob that does not open, or MissingPluginException
/// in an engine where the channel is not registered.
class FlakyVault extends MemoryVault {
  Object? failWith;
  @override
  Future<Uint8List?> read(String name) async {
    final Object? f = failWith;
    if (f != null && data.containsKey(name)) throw f; // a stored blob that does not open
    return super.read(name);
  }
}

E2eeService svcOn(FakeE2eeServer s, String user, E2eeVault v, {Future<String> Function()? uid}) =>
    E2eeService(api: s.client(user), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: uid ?? () async => user);

/// One isolate's view of shared preferences: [get] answers from its own cache
/// (like PrefsChannelKv's 2 s window), [getFresh] re-reads the shared store.
class IsolateKv implements ChannelKv {
  IsolateKv(this.shared);
  final MemoryKv shared;
  final Map<String, String?> _cache = <String, String?>{};
  @override
  Future<String?> get(String key) async => _cache.containsKey(key) ? _cache[key] : (_cache[key] = shared.data[key]);
  @override
  Future<String?> getFresh(String key) async => _cache[key] = shared.data[key];
  @override
  Future<void> set(String key, String value) async {
    shared.data[key] = value;
    _cache[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    shared.data.remove(key);
    _cache.remove(key);
  }
}

String? nothing() => null;

void main() {
  group('describeCircleError: only a real transport failure says "can\'t reach the server"', () {
    test('a TypeError (the old identity()! null check) gets its own words', () {
      Object err = 'none';
      try {
        nothing()!.length;
      } catch (e) {
        err = e;
      }
      expect(err, isA<TypeError>());
      final CircleException c = describeCircleError(err);
      expect(c.message, isNot(contains('reach the server')));
      expect(c.offline, isFalse);
      expect(c.message, contains('on this phone'));
    });

    test('a Keystore PlatformException is not a network problem', () {
      final CircleException c = describeCircleError(PlatformException(code: 'keystore', message: 'AEADBadTagException'));
      expect(c.message, isNot(contains('reach the server')));
      expect(c.offline, isFalse);
      expect(c.message, contains('PlatformException'));
    });

    test('this phone\'s key: a short real reason and the repair hint', () {
      final CircleException c = describeCircleError(const LocalKeyException(LocalKeyProblem.unreadable, cause: 'PlatformException'));
      expect(c.message, "This phone's encryption key could not be read. Open Encryption keys to repair.");
      expect(c.keyProblem, LocalKeyProblem.unreadable);
      expect(c.offline, isFalse);
      expect(describeCircleError(const VaultInvalidatedException()).keyProblem, LocalKeyProblem.invalidated);
      expect(describeCircleError(const VaultLockedException()).keyProblem, LocalKeyProblem.locked);
      expect(describeCircleError(const LocalKeyException(LocalKeyProblem.missing)).message, contains('no encryption key'));
    });

    test('transport failures still read as offline', () {
      final CircleException c = describeCircleError(TimeoutException('slow'));
      // A timeout is a transport failure (offline: true keeps the retry paths),
      // but the words say the server was slow, not that the phone is offline.
      expect(c.offline, isTrue);
      expect(c.message, contains('took too long to answer'));
      expect(c.message, isNot(contains('offline')));
    });

    test('server answers are unchanged', () {
      expect(describeCircleError(const ApiException(409, 'circle is not private')).message, 'circle is not private');
      expect(describeCircleError(const ApiException(409, 'circle is not private')).status, 409);
    });
  });

  group('E2eeService and this phone\'s key', () {
    late FakeE2eeServer server;
    setUp(() {
      server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      server.circle(priv, members: <String>[uA, uB], admin: uA);
    });

    test('disableCircle without a key on this phone: LocalKeyException(missing), not a TypeError', () async {
      final E2eeService admin = svcOn(server, uA, MemoryVault());
      await admin.registerThisDevice();
      await admin.enableCircle(priv);
      final E2eeService wiped = svcOn(server, uA, MemoryVault()); // same account, empty vault
      await expectLater(
          wiped.disableCircle(priv), throwsA(isA<LocalKeyException>().having((LocalKeyException e) => e.problem, 'problem', LocalKeyProblem.missing)));
    });

    test('disableCircle with an unreadable vault: LocalKeyException(unreadable) with the cause type', () async {
      final FlakyVault v = FlakyVault();
      final E2eeService admin = svcOn(server, uA, v);
      await admin.registerThisDevice();
      await admin.enableCircle(priv);
      // The app restarts (nothing cached) and the Keystore no longer opens the blobs.
      final E2eeService restarted = svcOn(server, uA, v);
      v.failWith = PlatformException(code: 'keystore', message: 'AEADBadTagException');
      await expectLater(
          restarted.disableCircle(priv),
          throwsA(isA<LocalKeyException>()
              .having((LocalKeyException e) => e.problem, 'problem', LocalKeyProblem.unreadable)
              .having((LocalKeyException e) => e.cause, 'cause', 'PlatformException')));
      // The channel missing in an engine is the same class of problem.
      v.failWith = MissingPluginException('no keystore here');
      await expectLater(restarted.requireIdentity(),
          throwsA(isA<LocalKeyException>().having((LocalKeyException e) => e.cause, 'cause', 'MissingPluginException')));
      // The vault's own exceptions keep their meaning.
      v.failWith = const VaultInvalidatedException();
      await expectLater(restarted.requireIdentity(), throwsA(isA<VaultInvalidatedException>()));
      // Nothing was regenerated or wiped meanwhile: once readable, the same key signs and the circle turns off.
      v.failWith = null;
      final String before = (await admin.identity())!.deviceId;
      expect((await restarted.requireIdentity()).deviceId, before);
      await restarted.disableCircle(priv);
      expect(server.circles[priv]!.mode, 'off');
    });

    test('an empty user id never wipes a stored identity', () async {
      final MemoryVault v = MemoryVault();
      final E2eeService a = svcOn(server, uA, v);
      await a.registerThisDevice();
      final int stored = v.data.length;
      final E2eeService confused = svcOn(server, uA, v, uid: () async => '');
      await expectLater(confused.identity(), throwsA(isA<LocalKeyException>()));
      expect(v.data.length, stored, reason: 'the identity must still be there');
      expect((await svcOn(server, uA, v).identity())!.deviceId, (await a.identity())!.deviceId);
    });
  });

  group('sealing failures are explained, and fixes are not lost', () {
    late FakeE2eeServer server;
    late FakeServer channel;
    late FakeClock clock;
    setUp(() {
      server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      server.circle(priv, members: <String>[uA, uB], admin: uA);
      channel = FakeServer();
      clock = FakeClock(DateTime.utc(2026, 11, 8, 12));
    });

    test('an unreadable key parks the fix with a reason; once readable it is sealed and the reason clears', () async {
      final FlakyVault v = FlakyVault();
      final E2eeService admin = svcOn(server, uA, v);
      await admin.registerThisDevice();
      await admin.enableCircle(priv);
      // A fresh process (the background isolate, or the app after a restart) over the same vault.
      final E2eeService svc = svcOn(server, uA, v);
      final MemoryKv kv = MemoryKv();
      final PrivateRuntime rt = PrivateRuntime(service: svc, api: server.client(uA), kv: kv, clock: clock, channel: channel);
      await rt.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      v.failWith = PlatformException(code: 'keystore', message: 'AEADBadTagException');
      kv.data['parked/v1'] = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'ts': clock.t.toIso8601String(), 'lat': 52.5, 'lon': 13.4, 'accuracy_meters': 8.0},
      ]);
      await rt.drainParked();
      LocalDelivery d = await rt.localDelivery(priv);
      expect(d.parked, 1, reason: 'never dropped, never plaintext');
      expect(d.sealProblem, contains('could not be read'));
      expect(jsonDecode(kv.data['sealerr/v1']!)['cause'], 'PlatformException');
      expect((await rt.fixCircle(priv)).single, contains('could not be read'),
          reason: '"Fix this circle" names the real problem instead of "waiting for the circle key"');

      v.failWith = null;
      await rt.drainParked();
      d = await rt.localDelivery(priv);
      expect(d.parked, 0);
      expect(d.sealProblem, isEmpty);
      expect(await rt.queue.length() + channel.items.length, greaterThan(0));
    });

    test('no key on this phone at all: the reason says so', () async {
      final E2eeService svc = svcOn(server, uA, MemoryVault());
      final MemoryKv kv = MemoryKv();
      final PrivateRuntime rt = PrivateRuntime(service: svc, api: server.client(uA), kv: kv, clock: clock, channel: channel);
      await rt.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      kv.data['parked/v1'] = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'ts': clock.t.toIso8601String(), 'lat': 52.5, 'lon': 13.4},
      ]);
      await rt.drainParked();
      expect((await rt.localDelivery(priv)).sealProblem, contains('no encryption key'));
    });
  });

  test('two isolates sealing for the same device never hand out the same seq', () async {
    final Phone p = await Phone.make(uA, 0xa1);
    final Keys keys = Keys()..byEpoch[1] = (Uint8List(32)..fillRange(0, 32, 0x42));
    final MemoryKv prefs = MemoryKv(); // the one SharedPreferences file both isolates use
    final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 8, 12));
    final ChannelSealer app = ChannelSealer(keys: keys, kv: IsolateKv(prefs), clock: clock);
    final ChannelSealer background = ChannelSealer(keys: keys, kv: IsolateKv(prefs), clock: clock);
    final Set<int> seqs = <int>{};
    for (int i = 0; i < 6; i++) {
      for (final ChannelSealer s in <ChannelSealer>[app, background]) {
        final WireItem it = await s.seal(p.id, priv, ChannelPurpose.fix, <String, dynamic>{'lat': 52.0 + i, 'lon': 13.4});
        expect(seqs.add(it.seq), isTrue, reason: 'seq ${it.seq} was used twice: the server would drop the second as a duplicate');
      }
    }
    expect(seqs.length, 12);
  });
}
