// A background isolate that cannot read its key parks every fix. On every heartbeat tick it reads the key again and,
// as soon as it can (the foreground repaired the vault), seals the parked fixes. It records what it did and never
// repairs anything itself.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';
import 'package:openfamily/services/diagnostics/tracking_journal.dart';
import 'package:openfamily/services/diagnostics/tracking_stats.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_e2ee_server.dart';
import 'local_key_problem_test.dart' show FlakyVault, svcOn;
import 'private_channel_test.dart' show FakeServer, FakeClock;
import 'private_runtime_test.dart' show circleOf, priv, uA, uB;

void main() {
  late FakeE2eeServer server;
  late FakeServer channel;
  late FakeClock clock;
  late FlakyVault v;
  late MemoryKv kv;
  late PrivateRuntime rt;

  Future<List<JournalLine>> bgLines() async =>
      (await TrackingJournal.instance.readAll()).where((JournalLine l) => l.source == 'bg').toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TrackingJournal.setSourceForTest('bg');
    TrackingStats.instance.resetForTest();
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(priv, members: <String>[uA, uB], admin: uA);
    channel = FakeServer();
    clock = FakeClock(DateTime.utc(2026, 11, 10, 22, 36));
    v = FlakyVault();
    final admin = svcOn(server, uA, v);
    await admin.registerThisDevice();
    await admin.enableCircle(priv);
    // The background isolate: a fresh service over the same vault, a headless runtime.
    kv = MemoryKv();
    rt = PrivateRuntime(service: svcOn(server, uA, v), api: server.client(uA), kv: kv, clock: clock, channel: channel);
    await rt.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
    kv.data['parked/v1'] = jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{'ts': clock.t.toIso8601String(), 'lat': 52.5, 'lon': 13.4, 'accuracy_meters': 8.0},
      <String, dynamic>{'ts': clock.t.add(const Duration(seconds: 1)).toIso8601String(), 'lat': 52.5, 'lon': 13.4},
    ]);
  });
  tearDown(() => TrackingJournal.setSourceForTest('app'));

  test('an unreadable key keeps the fixes, says why in the journal (once, folded), and retries every tick', () async {
    v.failWith = PlatformException(code: 'keystore', message: 'AEADBadTagException');
    for (int i = 0; i < 3; i++) {
      expect(await rt.backgroundDrainTick(), 0);
    }
    expect(jsonDecode(kv.data['parked/v1']!), hasLength(2), reason: 'nothing dropped, nothing sent in plaintext');
    final List<JournalLine> l = await bgLines();
    expect(l.single.event, 'background_drain_blocked');
    expect(l.single.detail, 'reason=unreadable');
    expect(l.single.count, 3);
    final StatsSnapshot s = await TrackingStats.instance.read();
    expect(s.lastSealError!.type, 'LocalKeyException');
    expect(s.lastSealError!.where, 'seal:unreadable');
  });

  test('when the key becomes readable the next tick seals the parked fixes and records background_drain', () async {
    v.failWith = PlatformException(code: 'keystore', message: 'AEADBadTagException');
    expect(await rt.backgroundDrainTick(), 0);
    v.failWith = null; // the foreground repaired the vault
    expect(await rt.backgroundDrainTick(), 2);
    expect(kv.data['parked/v1'], isNull);
    expect(await rt.queue.length() + channel.items.length, greaterThan(0));
    final List<JournalLine> l = await bgLines();
    expect(l.map((JournalLine x) => x.event), <String>['background_drain_blocked', 'background_drain']);
    expect(l.last.detail, 'waiting=2 sealed=2 left=0');
    // Nothing left: the next tick is silent and cheap.
    expect(await rt.backgroundDrainTick(), 0);
    expect((await bgLines()).length, 2);
  });

  test('one tick seals at most `limit` fixes and leaves the rest parked (a killed process loses at most that many)', () async {
    final List<Map<String, dynamic>> many = <Map<String, dynamic>>[
      for (int i = 0; i < 5; i++)
        <String, dynamic>{'ts': clock.t.add(Duration(seconds: i)).toIso8601String(), 'lat': 52.5, 'lon': 13.4},
    ];
    kv.data['parked/v1'] = jsonEncode(many);
    expect(await rt.backgroundDrainTick(limit: 2), 2);
    final List<dynamic> left = jsonDecode(kv.data['parked/v1']!) as List<dynamic>;
    expect(left, hasLength(3));
    expect((left.first as Map<String, dynamic>)['ts'], many[2]['ts'], reason: 'oldest first, the newest stay parked');
    expect((await bgLines()).single.detail, 'waiting=5 sealed=2 left=3');
    expect(await rt.backgroundDrainTick(limit: 10), 3);
    expect(kv.data['parked/v1'], isNull);
  });

  test('no key at all on the phone: blocked as missing, nothing repaired or created', () async {
    final PrivateRuntime empty = PrivateRuntime(
        service: svcOn(server, uA, MemoryVault()), api: server.client(uA), kv: kv, clock: clock, channel: channel);
    await empty.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
    expect(await empty.backgroundDrainTick(), 0);
    expect((await bgLines()).single.detail, 'reason=missing');
    expect(jsonDecode(kv.data['parked/v1']!), hasLength(2));
  });

  test('nothing parked: no identity read and no journal line', () async {
    kv.data.remove('parked/v1');
    v.failWith = PlatformException(code: 'keystore');
    expect(await rt.backgroundDrainTick(), 0);
    expect(await bgLines(), isEmpty);
  });

  test('a fix that cannot be sealed counts as a seal error with the exception type only', () async {
    v.failWith = PlatformException(code: 'keystore', message: 'lat=52.5 lon=13.4');
    await rt.drainParked();
    await TrackingStats.instance.flush();
    final StatsSnapshot s = await TrackingStats.instance.read();
    expect(s.hours.single[TrackCounter.sealErr], greaterThan(0));
    expect(s.hours.single[TrackCounter.parked], greaterThan(0));
    final SharedPreferences p = await SharedPreferences.getInstance();
    expect(p.getString('${TrackingStats.keyPrefix}bg')!.contains('lat='), isFalse);
  });
}
