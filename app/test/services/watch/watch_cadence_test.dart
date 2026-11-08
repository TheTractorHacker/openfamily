import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/alert_service.dart';
import 'package:openfamily/services/sharing_service.dart';
import 'package:openfamily/services/watch/watch_bridge.dart';
import 'package:openfamily/services/watch/watch_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'watch_scenarios.dart';

// Watch cadence (OPT-07/08, docs/design/WATCH_APPS.md "Cadence"): how many
// snapshots one simulated hour produces, how many of them are urgent, and that
// nothing the user waits for is held back.
//
// BEFORE numbers: the same three scenarios run through the pre-change bridge
// (5 s throttle, content hash with the millisecond fix time and the formatted
// status line, forced keep-alive every 10 min, alerts and pause polled every
// minute), measured with a replay of that logic against the v0.25.2 code
// (commit 4c8a7d9) before this change. Every one of those snapshots was urgent.
const int kBeforeDriving = 720;
const int kBeforeStationary = 125;
const int kBeforeAlertBurst = 125;

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this.cb);
  final DateTime due;
  final void Function() cb;
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A clock and timers that only move when the test says so.
class FakeTime {
  FakeTime(this.now);
  DateTime now;
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  Timer timer(Duration d, void Function() cb) {
    final _FakeTimer t = _FakeTimer(now.add(d), cb);
    _timers.add(t);
    return t;
  }

  Future<void> settle() async {
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Moves to [to], firing every timer that falls due on the way, in order.
  Future<void> advanceTo(DateTime to) async {
    while (true) {
      _timers.removeWhere((_FakeTimer t) => !t._active);
      final List<_FakeTimer> due = _timers.where((_FakeTimer t) => !t.due.isAfter(to)).toList()
        ..sort((_FakeTimer a, _FakeTimer b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      final _FakeTimer t = due.first;
      _timers.remove(t);
      t._active = false;
      if (t.due.isAfter(now)) now = t.due;
      t.cb();
      await settle();
    }
    now = to;
  }
}

class _Transport implements WatchTransport {
  final List<({DateTime at, String json, bool urgent})> sent = <({DateTime at, String json, bool urgent})>[];
  int cleared = 0;
  late FakeTime time;
  Future<void> Function(String)? onCommand;
  WatchLinkStatus st = const WatchLinkStatus(available: true, nodes: 1);

  @override
  Future<bool> publish(String json, {bool urgent = true}) async {
    sent.add((at: time.now, json: json, urgent: urgent));
    return true;
  }

  @override
  Future<bool> clear() async {
    cleared++;
    return true;
  }

  @override
  Future<void> allowPublish() async {}

  @override
  Future<WatchLinkStatus> status() async => st;

  @override
  void listen({required Future<void> Function(String json) onCommand, required void Function() onPeerChanged}) {
    this.onCommand = onCommand;
  }
}

class _Actions implements WatchActions {
  @override
  Future<void> sos() async {}
  @override
  Future<void> checkIn() async {}
  @override
  Future<DateTime?> pause(int minutes) async => null;
  @override
  Future<void> resume() async {}
  @override
  Future<void> ack(String alertId) async {}
  @override
  Future<void> reply(String text, {String? circleId}) async {}
}

/// Pushes a change event whenever alerts, unread or sharing differ, like the
/// real source does from the live socket.
class _Source implements WatchContextSource {
  WatchContext ctx = const WatchContext(chatCircleId: 'c1');
  final StreamController<void> _c = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _c.stream;

  @override
  void invalidate() {}

  @override
  Future<WatchContext> read() async => ctx;

  static String _key(WatchContext c) =>
      jsonEncode(<Object?>[for (final WatchAlert a in c.alerts) a.id, c.unread, c.sharingPaused, c.pausedUntil?.millisecondsSinceEpoch]);

  void set(WatchContext next) {
    final bool changed = _key(next) != _key(ctx);
    ctx = next;
    if (changed) _c.add(null);
  }
}

class SimResult {
  SimResult(this.sent);
  final List<({DateTime at, String json, bool urgent})> sent;
  int get total => sent.length;
  int get urgent => sent.where((({DateTime at, String json, bool urgent}) s) => s.urgent).length;

  /// Seconds from [t] to the first snapshot that satisfies [test].
  int? delay(DateTime t, bool Function(Map<String, dynamic> s) test) {
    for (final ({DateTime at, String json, bool urgent}) s in sent) {
      if (s.at.isBefore(t)) continue;
      if (test(jsonDecode(s.json) as Map<String, dynamic>)) return s.at.difference(t).inSeconds;
    }
    return null;
  }
}

String command(String name, DateTime at, String id, {String? arg}) =>
    jsonEncode(<String, dynamic>{'id': id, 'cmd': name, 'at': at.millisecondsSinceEpoch, if (arg != null) 'arg': arg});

/// Runs one hour. [visibleFrom]/[visibleTo] (seconds): the watch app is on
/// screen and repeats `visible` every 60 s, like the Wear and Apple apps do.
Future<SimResult> simulate(List<ScenarioSecond> s, {int? visibleFrom, int? visibleTo, String? visibleArg}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final FakeTime time = FakeTime(kScenarioStart);
  final _Transport t = _Transport()..time = time;
  final _Source src = _Source()..ctx = s.first.context;
  final WatchBridge b = WatchBridge(transport: t, actions: _Actions(), source: src, clock: () => time.now, timer: time.timer, supported: true);
  b.onMembers(s.first.members ?? const <Member>[], selfId: 'me'); // ignored before start, like a cold app
  await b.start();
  await time.settle();
  int ids = 0;
  for (int i = 0; i < s.length; i++) {
    await time.advanceTo(kScenarioStart.add(Duration(seconds: i)));
    src.set(s[i].context);
    if (visibleFrom != null && i >= visibleFrom && i < (visibleTo ?? s.length) && (i - visibleFrom) % 60 == 0) {
      await t.onCommand!(command('visible', time.now, 'v${ids++}', arg: visibleArg));
    }
    if (visibleTo != null && i == visibleTo) await t.onCommand!(command('hidden', time.now, 'h${ids++}'));
    final List<Member>? m = s[i].members;
    if (m != null) b.onMembers(m, selfId: 'me');
    await time.settle();
  }
  await time.advanceTo(kScenarioStart.add(Duration(seconds: s.length)));
  b.disposeForTest();
  return SimResult(t.sent);
}

Map<String, dynamic>? memberIn(Map<String, dynamic> snap, String id) {
  for (final Object? m in snap['members'] as List<dynamic>) {
    if (m is Map<String, dynamic> && m['id'] == id) return m;
  }
  return null;
}

void main() {
  group('one hour, watch app not on screen (hidden tier)', () {
    test('someone driving the whole hour', () async {
      final List<ScenarioSecond> hour = drivingHour();
      final SimResult r = await simulate(hour);
      // ignore: avoid_print
      print('CADENCE driving hidden: before $kBeforeDriving (all urgent), after ${r.total} (urgent ${r.urgent})');
      // One every 2 minutes at most, plus the first one.
      expect(r.total, lessThanOrEqualTo(32));
      expect(r.total, greaterThanOrEqualTo(25)); // the driver's position still reaches the watch
      expect(r.urgent, 2); // the start-up snapshot and the first roster after it
      // The position on the watch is never more than ~2 minutes (plus the 5 s floor) behind.
      for (int i = 1; i < r.sent.length; i++) {
        expect(r.sent[i].at.difference(r.sent[i - 1].at), lessThanOrEqualTo(const Duration(seconds: 130)));
      }
    });

    test('a still family with GPS jitter', () async {
      final SimResult r = await simulate(stationaryHour());
      // ignore: avoid_print
      print('CADENCE stationary hidden: before $kBeforeStationary (all urgent), after ${r.total} (urgent ${r.urgent})');
      // Start-up, the first roster, then a keep-alive every 10 minutes.
      expect(r.total, lessThanOrEqualTo(8));
      expect(r.urgent, 2);
    });

    test('an alert burst, chat messages and a pause', () async {
      final List<ScenarioSecond> hour = alertBurstHour();
      final SimResult r = await simulate(hour);
      // ignore: avoid_print
      print('CADENCE alert burst hidden: before $kBeforeAlertBurst (all urgent), after ${r.total} (urgent ${r.urgent})');
      expect(r.total, lessThanOrEqualTo(40));
      // Every alert reaches the watch within the 5 s floor, urgently.
      for (int k = 0; k < 4; k++) {
        final DateTime at = kScenarioStart.add(Duration(seconds: 600 + 30 * k));
        final int? d = r.delay(at, (Map<String, dynamic> s) => (s['alerts'] as List<dynamic>).any((dynamic a) => (a as Map)['id'] == 'a$k'));
        expect(d, isNotNull);
        expect(d, lessThanOrEqualTo(5));
        final ({DateTime at, String json, bool urgent}) first = r.sent.firstWhere(
            (({DateTime at, String json, bool urgent}) s) => !s.at.isBefore(at) && s.json.contains('"a$k"'));
        expect(first.urgent, true);
      }
      // The alerts ending also arrives at once.
      expect(r.delay(kScenarioStart.add(const Duration(seconds: 900)), (Map<String, dynamic> s) => (s['alerts'] as List<dynamic>).isEmpty), lessThanOrEqualTo(5));
      // Unread and pause: within seconds, but not urgent.
      expect(r.delay(kScenarioStart.add(const Duration(seconds: 1200)), (Map<String, dynamic> s) => s['unread'] == 1), lessThanOrEqualTo(5));
      expect(r.delay(kScenarioStart.add(const Duration(seconds: 2700)), (Map<String, dynamic> s) => (s['me'] as Map)['sharing'] == 'paused'), lessThanOrEqualTo(5));
      final int urgentNonAlert = r.sent.where((({DateTime at, String json, bool urgent}) s) => s.urgent && !s.json.contains('"alerts":[{')).length;
      expect(urgentNonAlert, lessThanOrEqualTo(3)); // start-up, first roster, the alerts ending
    });

    test('100 jittery fixes within 50 m produce no snapshot', () async {
      final List<ScenarioSecond> still = stationaryHour().sublist(0, 100);
      final SimResult r = await simulate(still);
      // Start-up and the first roster (within its first 5 s), then nothing.
      expect(r.total, 2);
      expect(r.sent.last.at.isAfter(kScenarioStart.add(const Duration(seconds: 6))), false);
    });
  });

  group('watch app on screen', () {
    test('visible: every change, at most one snapshot per 5 s, all urgent', () async {
      final SimResult r = await simulate(drivingHour(), visibleFrom: 0);
      // ignore: avoid_print
      print('CADENCE driving visible: before $kBeforeDriving, after ${r.total} (urgent ${r.urgent})');
      expect(r.total, lessThanOrEqualTo(721));
      expect(r.total, greaterThan(600));
      expect(r.urgent, r.total);
      for (int i = 1; i < r.sent.length; i++) {
        expect(r.sent[i].at.difference(r.sent[i - 1].at), greaterThanOrEqualTo(const Duration(seconds: 5)));
      }
    });

    test('visible on a still family: a keep-alive a minute keeps "Updated" current', () async {
      final SimResult r = await simulate(stationaryHour(), visibleFrom: 0);
      // ignore: avoid_print
      print('CADENCE stationary visible: after ${r.total} (urgent ${r.urgent})');
      expect(r.total, lessThanOrEqualTo(180));
      expect(r.total, greaterThanOrEqualTo(60));
    });

    test('ambient (always-on): meaningful changes once a minute', () async {
      final SimResult r = await simulate(drivingHour(), visibleFrom: 0, visibleArg: 'ambient');
      // ignore: avoid_print
      print('CADENCE driving ambient: after ${r.total} (urgent ${r.urgent})');
      expect(r.total, lessThanOrEqualTo(62));
      expect(r.total, greaterThanOrEqualTo(50));
    });

    test('a visible watch that goes quiet falls back to the hidden tier', () async {
      // visible only for the first 10 minutes, then the heartbeats stop (no "hidden" either).
      final List<ScenarioSecond> hour = drivingHour();
      final SimResult r = await simulate(hour, visibleFrom: 0, visibleTo: 600);
      final int late = r.sent.where((({DateTime at, String json, bool urgent}) s) => s.at.isAfter(kScenarioStart.add(const Duration(seconds: 900)))).length;
      expect(late, lessThanOrEqualTo(23)); // 45 minutes at one per 2 min
    });
  });

  group('presence commands', () {
    late FakeTime time;
    late _Transport t;
    late WatchBridge b;

    Future<void> make() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      time = FakeTime(kScenarioStart);
      t = _Transport()..time = time;
      b = WatchBridge(transport: t, actions: _Actions(), source: _Source(), clock: () => time.now, timer: time.timer, supported: true);
      await b.start();
      await time.settle();
    }

    tearDown(() => b.disposeForTest());

    test('visible, ambient and hidden set the tier; nothing is answered in lastCommand', () async {
      await make();
      expect(b.tier, WatchTier.hidden);
      await time.advanceTo(time.now.add(const Duration(seconds: 10)));
      await t.onCommand!(command('visible', time.now, 'p1'));
      await time.settle();
      expect(b.tier, WatchTier.visible);
      // Coming on screen sends a fresh snapshot at once, urgently.
      expect(t.sent.length, 2);
      expect(t.sent.last.urgent, true);
      expect((jsonDecode(t.sent.last.json) as Map<String, dynamic>).containsKey('lastCommand'), false);
      await t.onCommand!(command('visible', time.now, 'p2', arg: 'ambient'));
      expect(b.tier, WatchTier.ambient);
      await t.onCommand!(command('hidden', time.now, 'p3'));
      expect(b.tier, WatchTier.hidden);
    });

    test('a repeated visible inside 5 s does not send again; replays and stale ones are ignored', () async {
      await make();
      await time.advanceTo(time.now.add(const Duration(seconds: 10)));
      await t.onCommand!(command('visible', time.now, 'p1'));
      await time.settle();
      final int n = t.sent.length;
      await t.onCommand!(command('hidden', time.now, 'p2'));
      await t.onCommand!(command('visible', time.now, 'p3'));
      await time.settle();
      expect(t.sent.length, n);
      await t.onCommand!(command('hidden', time.now, 'p4'));
      await t.onCommand!(command('visible', time.now, 'p1')); // replayed id
      expect(b.tier, WatchTier.hidden);
      await t.onCommand!(command('visible', time.now.subtract(const Duration(minutes: 5)), 'old'));
      expect(b.tier, WatchTier.hidden);
      expect(t.sent.length, n);
    });

    test('the tier expires without heartbeats', () async {
      await make();
      await t.onCommand!(command('visible', time.now, 'p1'));
      expect(b.tier, WatchTier.visible);
      await time.advanceTo(time.now.add(const Duration(seconds: 151)));
      expect(b.tier, WatchTier.hidden);
      await t.onCommand!(command('visible', time.now, 'p2', arg: 'ambient'));
      await time.advanceTo(time.now.add(const Duration(minutes: 16)));
      expect(b.tier, WatchTier.hidden);
    });

    test('presence commands never publish after sign-out (the clear stays in force)', () async {
      await make();
      await b.signedOut();
      final int n = t.sent.length;
      await t.onCommand!(command('visible', time.now, 'p1'));
      await time.advanceTo(time.now.add(const Duration(minutes: 30)));
      expect(t.sent.length, n);
      expect(t.cleared, 1);
      expect((await SharedPreferences.getInstance()).getBool(WatchBridge.clearPendingKey), false);
      expect(b.tier, WatchTier.hidden);
    });

    test('a watch that disconnects and comes back gets a full urgent snapshot', () async {
      await make();
      await time.advanceTo(time.now.add(const Duration(minutes: 3)));
      t.st = const WatchLinkStatus(available: true, nodes: 0);
      await b.refreshLink();
      final int n = t.sent.length;
      t.st = const WatchLinkStatus(available: true, nodes: 1);
      await b.refreshLink();
      await time.settle();
      expect(t.sent.length, n + 1);
      expect(t.sent.last.urgent, true);
    });

    test('keep-alive: nothing for 10 minutes when nothing changed, then one non-urgent snapshot', () async {
      await make();
      final int n = t.sent.length;
      await time.advanceTo(time.now.add(const Duration(minutes: 9, seconds: 59)));
      expect(t.sent.length, n);
      await time.advanceTo(time.now.add(const Duration(seconds: 2)));
      expect(t.sent.length, n + 1);
      expect(t.sent.last.urgent, false);
    });
  });

  group('content hash stability', () {
    Member m({LatLng pos = const LatLng(51.5, -0.12), DateTime? fix, MovementType mv = MovementType.none, double? mps, PlacePresence? p, int battery = 80, MemberStatus status = MemberStatus.normal, DateTime? seen}) =>
        Member(
          id: 'sam',
          name: 'Sam',
          position: pos,
          status: status,
          batteryPercent: battery,
          address: '',
          movement: mv,
          speedMps: mps,
          fixTime: fix,
          lastSeen: seen ?? fix,
          placePresence: p,
          avatarColor: Colors.teal,
        );

    Map<String, dynamic> snap(Member x, DateTime now) =>
        buildWatchSnapshot(WatchSnapshotInput(now: now, signedIn: true, members: <Member>[x], selfId: 'me'));

    test('time passing alone never changes the hash ("Left Work 3 min ago" is formatted on the watch)', () {
      final DateTime t0 = kScenarioStart;
      final Member left = m(p: PlacePresence(placeId: 'w', placeName: 'Work', isAt: false, since: t0.subtract(const Duration(minutes: 3))), fix: t0);
      final Map<String, dynamic> a = snap(left, t0);
      final Map<String, dynamic> b = snap(left, t0.add(const Duration(minutes: 45)));
      expect(watchContentHash(a), watchContentHash(b));
      final Map<String, dynamic> sam = memberIn(a, 'sam')!;
      expect(sam['line'], 'Left Work');
      expect(sam['lineAt'], t0.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch);
      expect(classifyWatchChange(a, b), WatchChange.none);
    });

    test('a member whose updates stopped long ago: stable text plus lineAt', () {
      final DateTime seen = kScenarioStart.subtract(const Duration(days: 2));
      final Member x = m(status: MemberStatus.stopped, seen: seen);
      final ({String text, DateTime? at}) l = watchMemberLine(x, now: kScenarioStart);
      expect(l.text, 'Updates stopped, last seen');
      expect(l.at, seen);
    });

    test('the driving speed is rounded to 5 mph and is not a meaningful change', () {
      final Map<String, dynamic> a = snap(m(mv: MovementType.car, mps: 16.0, fix: kScenarioStart), kScenarioStart);
      final Map<String, dynamic> b = snap(m(mv: MovementType.car, mps: 16.4, fix: kScenarioStart), kScenarioStart);
      expect(memberIn(a, 'sam')!['line'], 'Driving 35 mph');
      expect(memberIn(a, 'sam')!['line'], memberIn(b, 'sam')!['line']);
      final Map<String, dynamic> c = snap(m(mv: MovementType.car, mps: 25, fix: kScenarioStart), kScenarioStart);
      expect(classifyWatchChange(a, c), WatchChange.minor);
    });

    test('what counts as meaningful', () {
      final DateTime t0 = kScenarioStart;
      final Map<String, dynamic> base = snap(m(fix: t0), t0);
      // A newer fix 30 m away: minor.
      expect(classifyWatchChange(base, snap(m(fix: t0.add(const Duration(seconds: 30)), pos: const LatLng(51.50027, -0.12)), t0)), WatchChange.minor);
      // 150 m away: meaningful.
      expect(classifyWatchChange(base, snap(m(fix: t0, pos: const LatLng(51.50135, -0.12)), t0)), WatchChange.meaningful);
      // Battery 80 -> 84: same 10% step; -> 79: next step; 21 -> 19: low.
      expect(classifyWatchChange(base, snap(m(fix: t0, battery: 84), t0)), WatchChange.minor);
      expect(classifyWatchChange(base, snap(m(fix: t0, battery: 79), t0)), WatchChange.meaningful);
      expect(classifyWatchChange(snap(m(fix: t0, battery: 21), t0), snap(m(fix: t0, battery: 19), t0)), WatchChange.meaningful);
      // Starts driving: meaningful.
      expect(classifyWatchChange(base, snap(m(fix: t0, mv: MovementType.car, mps: 10), t0)), WatchChange.meaningful);
      // Arrives at a place.
      expect(classifyWatchChange(base, snap(m(fix: t0, p: PlacePresence(placeId: 'h', placeName: 'Home', isAt: true, since: t0)), t0)), WatchChange.meaningful);
    });

    test('alerts, command answers and sign-in are urgent; unread and sharing are events', () {
      final DateTime t0 = kScenarioStart;
      WatchSnapshotInput input({List<WatchAlert> alerts = const <WatchAlert>[], int unread = 0, bool paused = false, WatchCommandResult? last, bool signedIn = true}) =>
          WatchSnapshotInput(now: t0, signedIn: signedIn, members: <Member>[m(fix: t0)], alerts: alerts, unread: unread, sharingPaused: paused, lastCommand: last);
      final Map<String, dynamic> base = buildWatchSnapshot(input());
      expect(classifyWatchChange(null, base), WatchChange.urgent);
      expect(classifyWatchChange(base, buildWatchSnapshot(input(alerts: <WatchAlert>[WatchAlert(id: 'a', kind: 'sos', from: 'Sam', at: t0)]))), WatchChange.urgent);
      expect(classifyWatchChange(base, buildWatchSnapshot(input(last: WatchCommandResult(id: 'k', cmd: 'checkin', ok: true, at: t0)))), WatchChange.urgent);
      expect(classifyWatchChange(base, buildWatchSnapshot(input(signedIn: false))), WatchChange.urgent);
      expect(classifyWatchChange(base, buildWatchSnapshot(input(unread: 2))), WatchChange.event);
      expect(classifyWatchChange(base, buildWatchSnapshot(input(paused: true))), WatchChange.event);
    });
  });

  group('ServiceWatchContextSource: pushed, not polled', () {
    test('an hour of snapshots costs 6 requests per kind instead of 60, and events refetch only what changed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DateTime now = kScenarioStart;
      int circles = 0, alerts = 0, pause = 0;
      final ServiceWatchContextSource src = ServiceWatchContextSource(
        listCircles: () async {
          circles++;
          return const <Circle>[];
        },
        listAlerts: () async {
          alerts++;
          return const <WatchAlert>[];
        },
        pauseStatus: () async {
          pause++;
          return const SharingPause(paused: false);
        },
        clock: () => now,
      );
      int events = 0;
      final StreamSubscription<void> sub = src.changes.listen((_) => events++);
      // The bridge reads at most every 5 s.
      for (int i = 0; i < 720; i++) {
        await src.read();
        now = now.add(const Duration(seconds: 5));
      }
      // ignore: avoid_print
      print('HTTP per hour for the watch: before 126 (circles 6, alerts 60, pause 60), after ${circles + alerts + pause} (circles $circles, alerts $alerts, pause $pause)');
      expect(circles, 6);
      expect(alerts, 6);
      expect(pause, 6);
      // Unchanged state: no request at all.
      now = now.subtract(const Duration(seconds: 5)); // still inside the hour
      final int before = circles + alerts + pause;
      await src.read();
      await src.read();
      expect(circles + alerts + pause, before);
      // An alert frame refetches alerts only, and tells the bridge.
      AlertEvents.handleFrame(<String, dynamic>{'type': 'alert', 'alert_id': 'x'});
      await Future<void>.delayed(Duration.zero);
      await src.read();
      expect(alerts, 7);
      expect(pause, 6);
      expect(events, 1);
      // This phone pausing sharing: pause only.
      SharingService.pauseChanges.value++;
      await src.read();
      expect(pause, 7);
      expect(alerts, 7);
      expect(events, 2);
      await sub.cancel();
    });
  });
}
