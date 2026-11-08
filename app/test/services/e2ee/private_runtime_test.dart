import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_history.dart';
import 'package:openfamily/services/e2ee/private_places.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import 'private_channel_test.dart' show FakeServer, FakeClock;

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String priv = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String std = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

Circle circleOf(String id, {bool isPrivate = false}) => Circle(
    id: id, name: id, role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: isPrivate ? 'private' : 'off');

class Device {
  Device(FakeE2eeServer server, FakeServer channel, this.user, FakeClock clock)
      : vault = MemoryVault(),
        kv = MemoryKv() {
    final E2eeService svc = E2eeService(
        api: server.client(user), vault: vault, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);
    service = svc;
    runtime = PrivateRuntime(
        service: svc, api: server.client(user), kv: kv, clock: clock, channel: channel,
        directory: StateSenderDirectory(server.client(user)));
    runtime.nameOf = (String id) => id == uA ? 'Alice' : 'Bob';
    runtime.notify = (String t, String b) async => notes.add(b);
    runtime.onMemberFrame = frames.add;
  }
  final String user;
  final MemoryVault vault;
  final MemoryKv kv;
  late final E2eeService service;
  late final PrivateRuntime runtime;
  final List<String> notes = <String>[];
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
}

void main() {
  late FakeE2eeServer e2eeServer;
  late FakeServer channel;
  late FakeClock clock;
  late Device a, b;

  setUp(() async {
    e2eeServer = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    e2eeServer.circle(priv, members: <String>[uA, uB], admin: uA);
    channel = FakeServer();
    clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    a = Device(e2eeServer, channel, uA, clock);
    b = Device(e2eeServer, channel, uB, clock);
    await a.service.registerThisDevice();
    await b.service.registerThisDevice();
    await a.service.enableCircle(priv);
    await b.service.syncCircleKeys(priv);
    await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
    await b.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
  });

  Map<String, dynamic> loc(double lat, double lon, {DateTime? at, double acc = 8}) => <String, dynamic>{
        'device_id': 'x', 'ts': (at ?? clock.t).toIso8601String(), 'lat': lat, 'lon': lon,
        'accuracy_meters': acc, 'speed_mps': 1.0, 'battery_pct': 77, 'motion_state': '', 'source': 'foreground',
      };

  group('sending with the screen locked', () {
    test('keys usable while locked: a fix is sealed and queued immediately, nothing is parked', () async {
      // The new wrapping key has no "unlocked device" condition, so the vault reads exactly as when unlocked.
      expect(await a.runtime.routeFix(loc(52.52, 13.4)), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await a.runtime.queue.length(), 1);
      expect(a.kv.data['parked/v1'], isNull);
    });

    test('an old key that is locked parks the fix (never plaintext) and the next unlock seals it', () async {
      // Device whose vault throws while "locked", like an un-migrated pre-0.24.2 Android key.
      final _LockableVault lv = _LockableVault(a.vault);
      final MemoryKv kv = MemoryKv();
      final E2eeService svc = E2eeService(
          api: e2eeServer.client(uA), vault: lv, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
      final PrivateRuntime rt = PrivateRuntime(
          service: svc, api: e2eeServer.client(uA), kv: kv, clock: clock, channel: channel,
          directory: StateSenderDirectory(e2eeServer.client(uA)));
      await rt.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      lv.locked = true;
      await rt.routeFix(loc(52.52, 13.4));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await rt.queue.length(), 0);
      expect(kv.data['parked/v1'], isNotNull);
      expect(kv.data['parked/v1'], isNot(contains('queue')));
      lv.locked = false;
      expect(await rt.drainParked(), 1);
      expect(await rt.queue.length(), 1);
    });
  });

  group('uplink rule for users in several circles', () {
    test('mode from circle modes', () {
      expect(uplinkModeFor(<String>{}, <String>{std}), UplinkMode.plaintextOnly);
      expect(uplinkModeFor(<String>{priv}, <String>{priv}), UplinkMode.sealedOnly);
      expect(uplinkModeFor(<String>{priv}, <String>{priv, std}), UplinkMode.both);
      expect(uplinkModeFor(<String>{}, <String>{}), UplinkMode.plaintextOnly); // unknown circles: unchanged behaviour
    });

    test('standard-only user: plaintext path is untouched and nothing is sealed', () async {
      await a.runtime.setCircles(<Circle>[circleOf(std)]);
      expect(await a.runtime.routeFix(loc(1, 2)), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await a.runtime.queue.length(), 0);
    });

    test('private-only user: no plaintext, a sealed copy is queued', () async {
      expect(await a.runtime.routeFix(loc(52.52, 13.4)), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await a.runtime.queue.length(), 1);
      expect(a.kv.data['queue/v1']!.contains('52.52'), isFalse); // the upload queue holds ciphertext only
    });

    test('mixed user: plaintext still goes to the standard circle, sealed copy to the private one only', () async {
      await a.runtime.setCircles(<Circle>[circleOf(std), circleOf(priv, isPrivate: true)]);
      expect(await a.runtime.routeFix(loc(52.52, 13.4)), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final List<WireItem> q = await a.runtime.queue.peek();
      expect(q.length, 1);
      expect(q.single.circleId, priv);
    });

    test('a failed seal (no key yet) never falls back to plaintext for the private circle', () async {
      final Device c = Device(e2eeServer, channel, uB, clock);
      await c.service.identity(create: true);
      await c.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      expect(await c.runtime.routeFix(loc(1, 2)), isFalse); // still: do not send plaintext
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await c.runtime.queue.length(), 0);
    });

    test('the modes persist for the background isolate', () async {
      final PrivateRuntime bg = PrivateRuntime(
          service: a.service, api: e2eeServer.client(uA), kv: a.kv, clock: clock, channel: channel);
      expect(await bg.uplinkMode(), UplinkMode.sealedOnly);
    });
  });

  group('end to end through the fake server', () {
    test('A sends a fix, B catches up and gets a map frame, the server only saw ciphertext', () async {
      await a.runtime.routeFix(loc(52.52, 13.4));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await a.runtime.flush(), 1);
      expect(channel.items.length, 1);
      final String wire = channel.items.map((WireItem i) => base64.encode(i.ciphertext)).join();
      expect(utf8.decode(channel.items.single.ciphertext, allowMalformed: true).contains('52.52'), isFalse);
      expect(wire.isNotEmpty, isTrue);

      final SyncStats s = await b.runtime.catchUp(priv);
      expect(s.accepted, 1);
      expect(b.frames.single['type'], 'location');
      expect(b.frames.single['user_id'], uA);
      expect(b.frames.single['circle_id'], priv);
      expect(b.frames.single['lat'], 52.52);
      expect(b.frames.single['battery_pct'], 77);
      // A's own phone ignores its own echo.
      await a.runtime.catchUp(priv);
      expect(a.frames, isEmpty);
    });

    test('live socket frame path and history store', () async {
      await a.runtime.routeFix(loc(10, 20, at: clock.t));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.runtime.flush();
      final WireItem w = channel.items.single;
      final Map<String, dynamic> frame = <String, dynamic>{
        'type': 'e2ee_item', 'circle_id': priv, 'id': 1, 'device_id': w.deviceId, 'seq': w.seq, 'purpose': w.purpose,
        'epoch': w.epoch, 'size_bucket': w.sizeBucket, 'ciphertext': base64.encode(w.ciphertext),
        'received_at': clock.t.toIso8601String(),
      };
      expect(await b.runtime.onWireFrame(frame), isTrue);
      expect(await b.runtime.onWireFrame(frame), isFalse); // replay of the same frame
      final List<TrackPoint> pts = await b.runtime.history.range(priv, uA, clock.t.subtract(const Duration(hours: 1)), clock.t.add(const Duration(hours: 1)));
      expect(pts.length, 1);
      expect(pts.single.lat, 10);
    });

    test('places are sealed, distributed, and the sender phone raises arrival events', () async {
      const SealedPlace home = SealedPlace(id: 'p1', name: 'Home', lat: 40, lon: -75, radiusMeters: 100);
      await b.runtime.savePlace(priv, home); // Bob (any member) adds a place
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await b.runtime.flush();
      await a.runtime.catchUp(priv);
      expect(a.runtime.places(priv).single.name, 'Home');

      // Alice walks: outside, then inside 5 min later. Her phone evaluates and seals the event.
      await a.runtime.routeFix(loc(40.003, -75, at: clock.t));
      clock.t = clock.t.add(const Duration(minutes: 5));
      await a.runtime.routeFix(loc(40, -75, at: clock.t, acc: 6));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await a.runtime.flush();
      await b.runtime.catchUp(priv);
      expect(b.notes, <String>['Alice arrived at Home']);
      expect(a.notes, isEmpty); // the sender is not notified about herself
      // Catch-up of the same items again does not notify twice.
      await b.runtime.catchUp(priv);
      expect(b.notes.length, 1);
    });

    test('old events replayed during catch-up stay silent', () async {
      await a.runtime.sendItem(priv, ChannelPurpose.event,
          <String, dynamic>{'k': 'place', 'a': 'enter', 'name': 'School'}, flushNow: false);
      await a.runtime.flush();
      clock.t = clock.t.add(const Duration(hours: 5));
      await b.runtime.catchUp(priv);
      expect(b.notes, isEmpty);
    });

    test('history chunks rebuild a track on a phone that was offline', () async {
      for (int i = 0; i < 3; i++) {
        await a.runtime.chunker.add(priv, TrackPoint(clock.t.add(Duration(minutes: i)).millisecondsSinceEpoch, 50.0 + i, 8.0));
      }
      final Map<String, dynamic>? chunk = await a.runtime.chunker.takeIfDue(priv, force: true);
      expect(chunk, isNotNull);
      await a.runtime.sendItem(priv, ChannelPurpose.history, chunk!, flushNow: false);
      await a.runtime.flush();
      await b.runtime.catchUp(priv);
      final List<TrackPoint> pts = await b.runtime.history.range(priv, uA, clock.t.subtract(const Duration(hours: 1)), clock.t.add(const Duration(hours: 2)));
      expect(pts.map((TrackPoint p) => p.lat).toList(), <double>[50, 51, 52]);
      expect(await a.runtime.chunker.takeIfDue(priv, force: true), isNull); // buffer drained
    });
  });

  group('history store', () {
    test('dedupes by timestamp, trims to the window and cap', () async {
      final PrivateHistory h = PrivateHistory(kv: MemoryKv(), maxPointsPerMember: 3, now: () => clock.t);
      final int t = clock.t.millisecondsSinceEpoch;
      await h.add(priv, uA, <TrackPoint>[TrackPoint(t, 1, 1), TrackPoint(t, 9, 9), TrackPoint(t + 1, 2, 2), TrackPoint(t + 2, 3, 3), TrackPoint(t + 3, 4, 4)]);
      final List<TrackPoint> all = await h.range(priv, uA, clock.t.subtract(const Duration(days: 1)), clock.t.add(const Duration(days: 1)));
      expect(all.map((TrackPoint p) => p.lat).toList(), <double>[2, 3, 4]);
      await h.add(priv, uA, <TrackPoint>[TrackPoint(t - const Duration(days: 30).inMilliseconds, 5, 5)]);
      expect((await h.range(priv, uA, DateTime.utc(2000), DateTime.utc(2100))).length, 3);
    });

    test('the chunker cuts on size or age', () async {
      final MemoryKv kv = MemoryKv();
      DateTime now = clock.t;
      final HistoryChunker ch = HistoryChunker(kv: kv, maxPoints: 3, maxAge: const Duration(minutes: 20), now: () => now);
      await ch.add(priv, TrackPoint(now.millisecondsSinceEpoch, 1, 1));
      expect(await ch.takeIfDue(priv), isNull);
      now = now.add(const Duration(minutes: 21));
      expect((await ch.takeIfDue(priv))!['pts'], isNotEmpty);
    });
  });

  test('notification text carries the place name only on the phone', () {
    expect(placeEventText('Bob', 'School', true), 'Bob arrived at School');
    expect(placeEventText('Bob', 'School', false), 'Bob left School');
  });
}

/// Vault that refuses to read while "locked" (the old unlocked-device-only key).
class _LockableVault implements E2eeVault {
  _LockableVault(this.inner);
  final E2eeVault inner;
  bool locked = false;
  @override
  Future<Uint8List?> read(String name) async {
    if (locked) throw const VaultLockedException();
    return inner.read(name);
  }

  @override
  Future<void> write(String name, Uint8List value) => inner.write(name, value);
  @override
  Future<void> delete(String name) => inner.delete(name);
  @override
  Future<List<String>> names() => inner.names();
  @override
  Future<KeystoreStatus> status() => inner.status();
}
