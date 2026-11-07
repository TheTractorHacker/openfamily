import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/processing/on_device_processor.dart';
import 'package:openfamily/services/processing/processing.dart';
import 'package:openfamily/services/processing/processing_source.dart';
import 'package:openfamily/services/processing/result_items.dart';

import '../services/e2ee/private_channel_test.dart' show FakeClock;
import '../support/fake_e2ee_server.dart';
import '../support/viewer_fixture.dart';

// Phase 4 + 5 seam: phone-only members compute trips / driving figures / weekly
// summaries on their own phone and publish them as sealed result items in their
// own lane; ProcessingSource merges server and phone sources per member.

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String priv = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

/// 4 min still, 8 min of driving at ~20 m/s with one hard braking, 4 min still.
List<Fix> driveTrack(DateTime start) {
  final List<Fix> out = <Fix>[];
  final int t0 = start.microsecondsSinceEpoch;
  double lat = 48.0;
  void add(int sec, double speed) => out.add(Fix(tsUs: t0 + sec * 1000000, lat: lat, lon: 11.0, speedMps: speed, accuracyM: 5));
  int s = 0;
  for (; s < 240; s += 10) {
    add(s, 0);
  }
  for (int i = 0; i < 480; i++, s++) {
    double v = 20;
    if (i >= 200 && i < 202) v = 20 - 5.0 * (i - 199); // 15, 10 m/s: a 5 m/s^2 braking
    if (i >= 202 && i < 210) v = 10 + (i - 201) * 1.25;
    lat += v / 111320.0;
    add(s, v);
  }
  for (int k = 0; k < 24; k++, s += 10) {
    add(s, 0);
  }
  return out;
}

void main() {
  group('result item bodies', () {
    test('trip / drive / week round trip and fit their buckets', () async {
      final TripSegmenter seg = TripSegmenter(finalizeOpen: true);
      seg.addAll(driveTrack(DateTime.utc(2026, 11, 2, 8)));
      final SegmentResult r = seg.finish();
      expect(r.trips, isNotEmpty);
      final ProcessedTrip t = r.trips.firstWhere((ProcessedTrip x) => x.mode == kModeDriving);
      final TripResult tr = TripResult.of(t);
      final TripResult? back = TripResult.tryParse(jsonDecode(jsonEncode(tr.toBody())));
      expect(back, isNotNull);
      expect((back!.id, back.startMs, back.mode), (tr.id, tr.startMs, kModeDriving));
      expect(back.distanceM, closeTo(t.distanceM, 0.1));
      expect(utf8.encode(jsonEncode(tr.toBody())).length + 90, lessThanOrEqualTo(ChannelPurpose.maxBucket[ChannelPurpose.trip]!));
      final DriveResult d = DriveResult.of(t);
      expect(DriveResult.tryParse(jsonDecode(jsonEncode(d.toBody())))!.tripId, tr.id);
      final WeekResult w = WeekResult.compute(<TripSummary>[TripSummary.of(t, id: tr.id)], t.events, DateTime.utc(2026, 11, 2).microsecondsSinceEpoch);
      expect(w.current.drives, 1);
      expect(WeekResult.tryParse(jsonDecode(jsonEncode(w.toBody())))!.current.drives, 1);
      expect(utf8.encode(jsonEncode(w.toBody())).length + 90, lessThanOrEqualTo(ChannelPurpose.maxBucket[ChannelPurpose.week]!));
    });

    test('a drive with hundreds of events is trimmed to fit, counts stay exact', () {
      final DriveResult d = DriveResult(
          tripId: 'p1',
          speeding: 0,
          hardBrake: 500,
          rapidAccel: 0,
          phoneUse: 0,
          events: <DriveEventResult>[
            for (int i = 0; i < 500; i++) DriveEventResult(kEventHardBrake, 1700000000000 + i, 1700000000500 + i, 4.1, 48.12345, 11.12345)
          ]);
      final Map<String, dynamic> b = d.fitBody(3600);
      expect(utf8.encode(jsonEncode(b)).length, lessThanOrEqualTo(3600));
      expect((b['n'] as List<dynamic>)[1], 500);
      expect(b['tr'], true);
      expect((b['ev'] as List<dynamic>).length, lessThan(500));
    });

    test('parsers reject anything out of range (a hostile member can send anything)', () {
      final Map<String, dynamic> ok = const TripResult(
              id: 'p1', startMs: 1700000000000, endMs: 1700000100000, distanceM: 1000, maxSpeedMps: 10, avgSpeedMps: 5, mode: kModeDriving,
              startLat: 1, startLon: 2, endLat: 3, endLon: 4)
          .toBody();
      expect(TripResult.tryParse(ok), isNotNull);
      for (final Map<String, dynamic> bad in <Map<String, dynamic>>[
        <String, dynamic>{...ok, 'sl': 91},
        <String, dynamic>{...ok, 'sn': -181},
        <String, dynamic>{...ok, 'mode': 'flying'},
        <String, dynamic>{...ok, 'e': 5},
        <String, dynamic>{...ok, 'dist': -1},
        <String, dynamic>{...ok, 'id': ''},
        <String, dynamic>{...ok, 'max': 1e9},
      ]) {
        expect(TripResult.tryParse(bad), isNull, reason: '$bad');
      }
      expect(DriveResult.tryParse(<String, dynamic>{'trip': 'p', 'n': <int>[1, 2, 3], 'ev': <dynamic>[]}), isNull);
      expect(DriveResult.tryParse(<String, dynamic>{'trip': 'p', 'n': <int>[1, 2, 3, 4], 'ev': <dynamic>[<dynamic>['nope', 1, 2, 3, 4, 5]]}), isNull);
      expect(WeekResult.tryParse(<String, dynamic>{'wk': 1, 'c': <String, dynamic>{}, 'p': <String, dynamic>{}}), isNull);
      expect(TripResult.tryParse('x'), isNull);
    });

    test('kinds equal the channel purposes', () {
      expect(kResultKinds, ChannelPurpose.results);
    });
  });

  group('OnDeviceProcessor', () {
    test('publishes trip + drive + week for a drive, once; a restart replay publishes nothing twice', () async {
      final MemoryKv kv = MemoryKv();
      final List<(String, Map<String, dynamic>)> out = <(String, Map<String, dynamic>)>[];
      OnDeviceProcessor mk() => OnDeviceProcessor(
          kv: kv,
          userId: uB,
          now: () => DateTime.utc(2026, 11, 2, 10),
          publish: (String k, Map<String, dynamic> b) async => out.add((k, b)));
      final List<Fix> track = driveTrack(DateTime.utc(2026, 11, 2, 8));
      final OnDeviceProcessor p = mk();
      int n = 0;
      for (final Fix f in track) {
        n += await p.onFix(f);
      }
      n += await p.finish();
      final List<String> kinds = out.map(((String, Map<String, dynamic>) e) => e.$1).toList();
      expect(kinds.where((String k) => k == kKindTrip), hasLength(1));
      expect(kinds.where((String k) => k == kKindDrive), hasLength(1));
      expect(kinds.where((String k) => k == kKindWeek), hasLength(1));
      expect(n, 3);
      final DriveResult drive = DriveResult.tryParse(out.firstWhere(((String, Map<String, dynamic>) e) => e.$1 == kKindDrive).$2)!;
      expect(drive.hardBrake, greaterThanOrEqualTo(1), reason: 'the 5 m/s^2 braking is a hard-brake event');
      final WeekResult week = WeekResult.tryParse(out.firstWhere(((String, Map<String, dynamic>) e) => e.$1 == kKindWeek).$2)!;
      expect(week.current.drives, 1);
      expect(week.weekStartMs, DateTime.utc(2026, 11, 2).millisecondsSinceEpoch);
      // A new process replays the same fixes (restore): nothing is published again.
      final int before = out.length;
      final OnDeviceProcessor p2 = mk();
      await p2.restore(track);
      await p2.finish();
      expect(out.length, before);
    });

    test('the finished week is published once when it is due, and never for a phone that did not move', () async {
      final MemoryKv kv = MemoryKv();
      final List<String> out = <String>[];
      DateTime now = DateTime.utc(2026, 11, 8, 12); // Sunday before 18:00 UTC
      final OnDeviceProcessor p = OnDeviceProcessor(kv: kv, userId: uB, now: () => now, publish: (String k, Map<String, dynamic> b) async => out.add(k));
      expect(await p.tickWeekly(), isFalse, reason: 'no trips: nothing is sent');
      expect(out, isEmpty);
      // A phone with a trip in the finished week.
      final MemoryKv kv2 = MemoryKv();
      final OnDeviceProcessor q = OnDeviceProcessor(kv: kv2, userId: uB, now: () => now, publish: (String k, Map<String, dynamic> b) async => out.add(k));
      for (final Fix f in driveTrack(DateTime.utc(2026, 10, 27, 8))) {
        await q.onFix(f);
      }
      await q.finish();
      out.clear();
      expect(await q.tickWeekly(), isTrue);
      expect(await q.tickWeekly(), isFalse);
      expect(out, <String>[kKindWeek]);
    });

    test('phone results equal what the pinned server functions give for the same trips (shared computeWeekStat)', () {
      final TripSegmenter seg = TripSegmenter(finalizeOpen: true)..addAll(driveTrack(DateTime.utc(2026, 11, 2, 8)));
      final SegmentResult r = seg.finish();
      final List<TripSummary> ts = <TripSummary>[for (final ProcessedTrip t in r.trips) TripSummary.of(t)];
      final List<DrivingEvent> ev = <DrivingEvent>[for (final ProcessedTrip t in r.trips) ...t.events];
      final int wk = DateTime.utc(2026, 11, 2).microsecondsSinceEpoch;
      final WeekStatOut direct = computeWeekStat(ts, ev, fromUs: wk, toUs: wk + 7 * 24 * 3600 * 1000000);
      final WeekResult via = WeekResult.compute(ts, ev, wk);
      expect(via.current.drives, direct.drives);
      expect(via.current.distanceM, closeTo(direct.distanceM, 0.1));
      expect(via.current.score, direct.score);
      expect(via.current.hardBrake, direct.events.hardBrake);
    });
  });

  group('ProcessingSource', () {
    ReceivedItem item(String user, String purpose, Map<String, dynamic> body, {int seq = 1, DateTime? at}) => ReceivedItem(
        circleId: priv, deviceId: 'd', userId: user, seq: seq, purpose: purpose, epoch: 1, ts: at ?? DateTime.utc(2026, 11, 2, 9), body: body);

    TripResult trip(int startMs, {String id = 'p1'}) => TripResult(
        id: id, startMs: startMs, endMs: startMs + 600000, distanceM: 5000, maxSpeedMps: 20, avgSpeedMps: 10, mode: kModeDriving,
        startLat: 1, startLon: 2, endLat: 3, endLon: 4);

    test('server member from the server, phone-only member from result items, and an explicit placeholder', () async {
      final ResultStore store = ResultStore(MemoryKv());
      final DateTime from = DateTime.utc(2026, 11, 1), to = DateTime.utc(2026, 11, 8);
      final int inRange = DateTime.utc(2026, 11, 2, 8).millisecondsSinceEpoch;
      await store.put(item(uB, ChannelPurpose.trip, trip(inRange).toBody()));
      await store.put(item(uB, ChannelPurpose.trip, trip(DateTime.utc(2026, 10, 1).millisecondsSinceEpoch, id: 'old').toBody(), seq: 2));
      const String uC = '33333333-3333-4333-8333-333333333333';
      final ProcessingSource src = ProcessingSource(
        memberLanes: (String c) async => <MemberLaneView>[
          const MemberLaneView(uA, E2ee.lineServer, 0, verified: true),
          const MemberLaneView(uB, E2ee.linePhone, 0, verified: true),
          const MemberLaneView(uC, E2ee.linePhone, 0, verified: false),
        ],
        results: store,
        server: _FakeServerReader(<TripResult>[trip(inRange, id: 'srv')]),
      );
      final List<MemberProcessing> got = await src.load(priv, from: from, to: to);
      final MemberProcessing a = got.firstWhere((MemberProcessing m) => m.userId == uA);
      final MemberProcessing b = got.firstWhere((MemberProcessing m) => m.userId == uB);
      final MemberProcessing c = got.firstWhere((MemberProcessing m) => m.userId == uC);
      expect((a.origin, a.trips.single.id, a.placeholder), (ProcessingOrigin.server, 'srv', null));
      expect((b.origin, b.trips.single.id, b.placeholder), (ProcessingOrigin.phone, 'p1', null));
      expect(b.updatedAt, isNotNull);
      expect(c.origin, ProcessingOrigin.phone);
      expect(c.trips, isEmpty);
      expect(c.placeholder, PlaceholderReason.notSharedYet);
      // Nothing silently dropped: a server that cannot be reached is a placeholder too.
      final List<MemberProcessing> down = await ProcessingSource(
              memberLanes: (String c) async => <MemberLaneView>[const MemberLaneView(uA, E2ee.lineServer, 0, verified: true)], results: store)
          .load(priv, from: from, to: to);
      expect(down.single.placeholder, PlaceholderReason.serverUnavailable);
    });

    test('newest copy wins, malformed or foreign-kind items are not stored', () async {
      final ResultStore store = ResultStore(MemoryKv());
      final int t = DateTime.utc(2026, 11, 2, 8).millisecondsSinceEpoch;
      await store.put(item(uB, ChannelPurpose.trip, trip(t).toBody(), seq: 5, at: DateTime.utc(2026, 11, 2, 9)));
      await store.put(item(uB, ChannelPurpose.trip, <String, dynamic>{...trip(t).toBody(), 'dist': 9999.0}, seq: 6, at: DateTime.utc(2026, 11, 2, 10)));
      await store.put(item(uB, ChannelPurpose.trip, <String, dynamic>{...trip(t).toBody(), 'dist': 1.0}, seq: 4, at: DateTime.utc(2026, 11, 2, 8))); // older
      expect((await store.trips(priv, uB)).single.distanceM, 9999.0);
      expect(await store.put(item(uB, ChannelPurpose.trip, <String, dynamic>{'id': 'x'})), isFalse);
      expect(await store.put(item(uB, ChannelPurpose.fix, <String, dynamic>{'lat': 1, 'lon': 2})), isFalse);
      // The author is the verified sender: another member's items never land in Bob's list.
      await store.put(item(uA, ChannelPurpose.trip, trip(t, id: 'a1').toBody()));
      expect((await store.trips(priv, uB)).map((TripResult x) => x.id), <String>['p1']);
    });
  });

  group('wired into the runtime: a phone-only member\'s phone computes and publishes in the phone lane', () {
    late FakeE2eeServer server;
    late FakeLaneChannel channel;
    late FakeClock clock;

    Future<({PrivateRuntime rt, E2eeService svc, MemoryKv kv})> mk(String user) async {
      final MemoryKv kv = MemoryKv();
      final E2eeService svc = E2eeService(
          api: server.client(user), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);
      final PrivateRuntime rt = PrivateRuntime(
          service: svc, api: server.client(user), kv: kv, clock: clock, channel: channel, directory: StateSenderDirectory(server.client(user)));
      rt.lanesService.logTtl = Duration.zero;
      rt.notify = (String t, String b) async {};
      await svc.registerThisDevice();
      return (rt: rt, svc: svc, kv: kv);
    }

    Circle circle() => Circle(id: priv, name: 'p', role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');

    setUp(() {
      server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      clock = FakeClock(DateTime.utc(2026, 11, 2, 8));
      server.now = () => clock.t;
      server.circle(priv, members: <String>[uA, uB], admin: uA);
      channel = FakeLaneChannel(server);
    });

    Map<String, dynamic> loc(Fix f) => <String, dynamic>{
          'ts': f.time.toIso8601String(), 'lat': f.lat, 'lon': f.lon, 'accuracy_meters': f.accuracyM, 'speed_mps': f.speedMps,
          'battery_pct': 50, 'motion_state': '',
        };

    test('trips, drives and the week reach the other member sealed in the PHONE lane; the server sees ciphertext only', () async {
      final a = await mk(uA);
      final b = await mk(uB);
      await a.svc.enableCircle(priv);
      await b.svc.syncCircleKeys(priv);
      await a.rt.setCircles(<Circle>[circle()]);
      await b.rt.setCircles(<Circle>[circle()]);
      // Bob is phone-only (no pref at all = phone). Feed his drive through the real pipeline.
      for (final Fix f in driveTrack(DateTime.utc(2026, 11, 2, 8))) {
        clock.t = f.time;
        await b.rt.routeFix(loc(f));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // A later fix after a long gap closes the trip for sure.
      clock.t = clock.t.add(const Duration(minutes: 30));
      await b.rt.routeFix(loc(Fix(tsUs: clock.t.microsecondsSinceEpoch, lat: 48.9, lon: 11.0, speedMps: 0, accuracyM: 5)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await b.rt.flush();
      expect(channel.items.where((WireItem i) => i.line == E2ee.lineServer), isEmpty);
      final Map<String, int> byPurpose = <String, int>{};
      for (final WireItem i in channel.items) {
        byPurpose[i.purpose] = (byPurpose[i.purpose] ?? 0) + 1;
      }
      expect(byPurpose[ChannelPurpose.trip], greaterThanOrEqualTo(1), reason: '$byPurpose');
      expect(byPurpose[ChannelPurpose.drive], greaterThanOrEqualTo(1));
      expect(byPurpose[ChannelPurpose.week], greaterThanOrEqualTo(1));
      // Alice's phone receives and stores them under Bob.
      await a.rt.catchUp(priv);
      final List<TripResult> trips = await a.rt.results.trips(priv, uB);
      expect(trips, isNotEmpty);
      expect(trips.any((TripResult t) => t.mode == kModeDriving && t.distanceM > 5000), isTrue);
      expect((await a.rt.results.weeks(priv, uB)).first.current.drives, greaterThanOrEqualTo(1));
      expect((await a.rt.results.drives(priv, uB)).any((DriveResult d) => d.hardBrake >= 1), isTrue);
      // The screens' data layer: Bob is phone-only, so his figures come from those items.
      final ProcessingSource src = ProcessingSource(memberLanes: a.rt.lanesService.members, results: a.rt.results);
      await a.rt.lanesService.refresh(priv);
      final MemberProcessing mb =
          (await src.load(priv, from: DateTime.utc(2026, 11, 1), to: DateTime.utc(2026, 11, 9))).firstWhere((MemberProcessing m) => m.userId == uB);
      expect((mb.origin, mb.placeholder), (ProcessingOrigin.phone, null));
      expect(mb.trips, isNotEmpty);
      // Nothing readable in what the server stored.
      final String blob = channel.items.map((WireItem i) => latin1.decode(i.ciphertext)).join();
      expect(blob.contains('48.'), isFalse);
    });

    test('a server-assisted member gets NO on-device results (the server computes them)', () async {
      final a = await mk(uA);
      final b = await mk(uB);
      await a.svc.enableCircle(priv);
      await b.svc.syncCircleKeys(priv);
      for (final PrivateRuntime r in <PrivateRuntime>[a.rt, b.rt]) {
        await r.setCircles(<Circle>[circle()]);
      }
      final ViewerFixture srv = await ViewerFixture.create(uA);
      final String ap = await a.svc.approveLinkRequest(await a.svc.inspectViewerRequest(await srv.request(kind: 'server', name: 'srv')));
      final DeviceKey sk = await srv.register(server, ap, kind: 'server', label: 'srv');
      server.pinnedServerDevice = srv.deviceId;
      await a.rt.lanesService.publishPolicy(priv, serverAssist: true);
      await b.rt.lanesService.refresh(priv);
      await b.rt.lanesService.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: sk.fingerprint);
      expect(await b.rt.phoneOnlyCircles(), isEmpty);
      for (final Fix f in driveTrack(DateTime.utc(2026, 11, 2, 8)).take(300)) {
        clock.t = f.time;
        await b.rt.routeFix(loc(f));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final List<WireItem> q = await b.rt.queue.peek();
      expect(q.where((WireItem i) => ChannelPurpose.results.contains(i.purpose)), isEmpty);
      expect(q.where((WireItem i) => i.purpose == 'fix').every((WireItem i) => i.line == E2ee.lineServer), isTrue);
    });
  });
}

class _FakeServerReader implements ServerProcessingReader {
  _FakeServerReader(this.t);
  final List<TripResult> t;
  @override
  Future<List<TripResult>> trips(String circleId, String userId, DateTime from, DateTime to) async => t;
  @override
  Future<WeekResult?> week(String circleId, String userId, int weekStartMs) async => null;
}
