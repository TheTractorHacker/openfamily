import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/send_policy.dart';

final DateTime t0 = DateTime.utc(2026, 1, 1, 12);

SendFix fix(DateTime ts, {double lat = 48.0, double lon = 2.0, double speed = 0.5}) =>
    SendFix(lat: lat, lon: lon, ts: ts, speed: speed);

SendInput inp({
  SendTier tier = SendTier.walking,
  DateTime? now,
  SendFix? f,
  bool boost = false,
  bool fg = false,
  String source = 'background',
  DateTime? lastSentAt,
  ({double lat, double lon})? lastPos = const (lat: 48.0, lon: 2.0),
  SendTier? lastTier,
  DateTime? heldOldest,
  int held = 0,
  bool privateOnly = false,
}) {
  final DateTime n = now ?? t0.add(const Duration(seconds: 5));
  return SendInput(
    tier: tier,
    now: n,
    fix: f ?? fix(n),
    liveBoostActive: boost,
    fgPresenceFresh: fg,
    source: source,
    lastSentAt: lastSentAt ?? t0,
    lastSentPos: lastPos,
    lastTier: lastTier ?? tier,
    heldOldestAt: heldOldest,
    heldCount: held,
    privateOnly: privateOnly,
  );
}

Map<String, dynamic> body(DateTime ts) =>
    <String, dynamic>{'ts': ts.toIso8601String(), 'lat': 1.0, 'lon': 2.0};

void expectFlush(SendDecision d) {
  expect(d.action, SendAction.sendNow);
  expect(d.flushHeldFirst, isTrue);
}

void main() {
  group('decide: immediate sends', () {
    test('fast tier', () => expectFlush(SendPolicy.decide(inp(tier: SendTier.fast))));
    test('live boost', () => expectFlush(SendPolicy.decide(inp(boost: true))));
    test('requested', () => expectFlush(SendPolicy.decide(inp(source: 'requested'))));
    test('fg presence', () => expectFlush(SendPolicy.decide(inp(fg: true))));
    test('first fix', () {
      final SendInput i = SendInput(
          tier: SendTier.walking, now: t0, fix: fix(t0));
      expectFlush(SendPolicy.decide(i));
    });
    test('tier change', () => expectFlush(SendPolicy.decide(
        inp(tier: SendTier.walking, lastTier: SendTier.stillIdle))));
    test('walking breakout >= 150 m', () {
      // ~0.00145 deg lat = ~161 m
      expectFlush(SendPolicy.decide(inp(f: fix(t0.add(const Duration(seconds: 5)), lat: 48.00145))));
    });
  });

  group('decide: walking hold', () {
    test('holds at 5 s intervals then the 10th point flushes', () {
      int held = 0;
      DateTime? oldest;
      int flushes = 0;
      for (int k = 1; k <= 11; k++) {
        final DateTime n = t0.add(Duration(seconds: 3 * k));
        final SendDecision d = SendPolicy.decide(
            inp(now: n, heldOldest: oldest, held: held, lastSentAt: t0));
        if (d.action == SendAction.hold) {
          held++;
          oldest ??= n;
        } else {
          flushes++;
          expect(held, 10);
          break;
        }
      }
      expect(flushes, 1);
    });
    test('age 45 s flushes', () {
      final DateTime n = t0.add(const Duration(seconds: 50));
      expectFlush(SendPolicy.decide(
          inp(now: n, heldOldest: t0.add(const Duration(seconds: 5)), held: 3)));
    });
    test('privateOnly never holds', () {
      expectFlush(SendPolicy.decide(inp(privateOnly: true)));
    });
  });

  group('decide: still', () {
    final SendTier s = SendTier.stillIdle;
    test('suppress under 4 min', () {
      final SendDecision d = SendPolicy.decide(inp(
          tier: s, now: t0.add(const Duration(minutes: 3)), f: fix(t0.add(const Duration(minutes: 3)), lat: 48.0001)));
      expect(d.action, SendAction.suppress);
    });
    test('sendNow at >= 4 min', () {
      expectFlush(SendPolicy.decide(
          inp(tier: s, now: t0.add(const Duration(minutes: 4)))));
    });
    test('30 m gives sendNow', () {
      // 0.00027 deg lat ~ 30 m
      expectFlush(SendPolicy.decide(inp(
          tier: s, now: t0.add(const Duration(minutes: 1)),
          f: fix(t0.add(const Duration(minutes: 1)), lat: 48.00027))));
    });
    test('2 m/s gives sendNow', () {
      expectFlush(SendPolicy.decide(inp(
          tier: s, now: t0.add(const Duration(minutes: 1)),
          f: fix(t0.add(const Duration(minutes: 1)), speed: 2))));
    });
  });

  group('flushHeld', () {
    test('batch oldest first, never the freshest ts, batch then single', () async {
      final List<String> order = <String>[];
      final List<List<Map<String, dynamic>>> batches = <List<Map<String, dynamic>>>[];
      final List<Map<String, dynamic>> singles = <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> held = <Map<String, dynamic>>[
        for (int k = 3; k >= 1; k--) body(t0.add(Duration(seconds: k))),
      ];
      final Map<String, dynamic> fresh = body(t0.add(const Duration(seconds: 10)));
      await flushHeld(
        held: held,
        freshest: fresh,
        sendBatch: (List<Map<String, dynamic>> c) async {
          order.add('batch');
          batches.add(c);
          return true;
        },
        sendSingle: (Map<String, dynamic> b) async {
          order.add('single');
          singles.add(b);
          return SingleOutcome.ok;
        },
        spill: (_) async => fail('no spill'),
      );
      expect(order, <String>['batch', 'single']);
      final List<String> tss = batches.single.map((Map<String, dynamic> p) => '${p['ts']}').toList();
      expect(tss, <String>[...tss]..sort());
      expect(tss, isNot(contains(fresh['ts'])));
      expect(singles.single, fresh);
    });

    test('chunks of 100', () async {
      final List<int> sizes = <int>[];
      await flushHeld(
        held: <Map<String, dynamic>>[
          for (int k = 0; k < 250; k++) body(t0.add(Duration(seconds: k))),
        ],
        freshest: body(t0.add(const Duration(hours: 1))),
        sendBatch: (List<Map<String, dynamic>> c) async {
          sizes.add(c.length);
          return true;
        },
        sendSingle: (_) async => SingleOutcome.ok,
        spill: (_) async {},
      );
      expect(sizes, <int>[100, 100, 50]);
    });

    test('batch failure spills held and still sends single', () async {
      final List<Map<String, dynamic>> spilled = <Map<String, dynamic>>[];
      bool single = false;
      final FlushResult r = await flushHeld(
        held: <Map<String, dynamic>>[body(t0), body(t0.add(const Duration(seconds: 1)))],
        freshest: body(t0.add(const Duration(seconds: 9))),
        sendBatch: (_) async => throw Exception('net'),
        sendSingle: (_) async {
          single = true;
          return SingleOutcome.ok;
        },
        spill: (List<Map<String, dynamic>> p) async => spilled.addAll(p),
      );
      expect(spilled.length, 2);
      expect(single, isTrue);
      expect(r.singleSent, isTrue);
    });

    test('single failure spills the freshest body', () async {
      final List<Map<String, dynamic>> spilled = <Map<String, dynamic>>[];
      final Map<String, dynamic> fresh = body(t0.add(const Duration(seconds: 9)));
      await flushHeld(
        held: <Map<String, dynamic>>[body(t0)],
        freshest: fresh,
        sendBatch: (_) async => true,
        sendSingle: (_) async => SingleOutcome.failed,
        spill: (List<Map<String, dynamic>> p) async => spilled.addAll(p),
      );
      expect(spilled, <Map<String, dynamic>>[fresh]);
    });

    test('400 not newer is not spilled', () async {
      final FlushResult r = await flushHeld(
        held: const <Map<String, dynamic>>[],
        freshest: body(t0),
        sendBatch: (_) async => true,
        sendSingle: (_) async => SingleOutcome.notNewer,
        spill: (_) async => fail('no spill'),
      );
      expect(r.singleSent, isTrue);
    });
  });

  group('heartbeatAction', () {
    test('flush on every tick whatever the held age', () {
      expect(
          heartbeatAction(
              now: t0.add(const Duration(seconds: 90)),
              lastSentAt: t0,
              heldOldestAt: t0,
              cachedFix: fix(t0)),
          HeartbeatAction.flushHeld);
      expect(
          heartbeatAction(
              now: t0.add(const Duration(seconds: 89)),
              lastSentAt: t0,
              heldOldestAt: t0,
              cachedFix: fix(t0)),
          HeartbeatAction.flushHeld);
    });
    test('no refresh of a fix the server already has', () {
      final DateTime n = t0.add(const Duration(minutes: 6));
      expect(
          heartbeatAction(
              now: n,
              lastSentAt: t0,
              heldOldestAt: null,
              cachedFix: fix(t0.add(const Duration(minutes: 1))),
              lastSentTs: t0.add(const Duration(minutes: 1))),
          HeartbeatAction.none);
      expect(
          heartbeatAction(
              now: n,
              lastSentAt: t0,
              heldOldestAt: null,
              cachedFix: fix(t0.add(const Duration(minutes: 2))),
              lastSentTs: t0.add(const Duration(minutes: 1))),
          HeartbeatAction.refreshFreshest);
    });
    test('refresh at 5 min with a cached fix', () {
      final DateTime n = t0.add(const Duration(minutes: 5));
      expect(
          heartbeatAction(
              now: n, lastSentAt: t0, heldOldestAt: null, cachedFix: fix(n)),
          HeartbeatAction.refreshFreshest);
    });
    test('nothing without a cached fix', () {
      expect(
          heartbeatAction(
              now: t0.add(const Duration(minutes: 9)),
              lastSentAt: t0,
              heldOldestAt: null,
              cachedFix: null),
          HeartbeatAction.none);
    });
    test('nothing if the cached fix is older than 14 min', () {
      expect(
          heartbeatAction(
              now: t0.add(const Duration(minutes: 15)),
              lastSentAt: t0,
              heldOldestAt: null,
              cachedFix: fix(t0)),
          HeartbeatAction.none);
    });
  });

  group('simulation', () {
    // Drives the policy + heartbeat like the isolate does. Returns send times.
    ({List<DateTime> sends, int singles, int maxHeld, Duration maxHeldAge}) sim({
      required SendTier tier,
      required int fixEverySec,
      required Duration total,
      bool jitter = false,
      double stepM = 0,
    }) {
      final math.Random rnd = math.Random(7);
      final List<DateTime> sends = <DateTime>[t0];
      DateTime lastSentAt = t0;
      ({double lat, double lon}) lastPos = (lat: 48.0, lon: 2.0);
      double lat = 48.0;
      final List<DateTime> held = <DateTime>[];
      SendTier? lastTier = tier;
      SendFix? cached;
      int singles = 1;
      int maxHeld = 0;
      Duration maxAge = Duration.zero;
      DateTime now = t0;
      DateTime nextHb = t0.add(const Duration(minutes: 10));
      DateTime nextFix = t0;
      void send(DateTime at, SendFix f) {
        singles++;
        sends.add(at);
        lastSentAt = at;
        lastPos = (lat: f.lat, lon: f.lon);
        held.clear();
      }

      while (now.difference(t0) < total) {
        final DateTime step = nextFix.isBefore(nextHb) ? nextFix : nextHb;
        now = step;
        if (now.difference(t0) >= total) break;
        if (now == nextHb) {
          nextHb = nextHb.add(const Duration(minutes: 10));
          final HeartbeatAction a = heartbeatAction(
              now: now,
              lastSentAt: lastSentAt,
              heldOldestAt: held.isEmpty ? null : held.first,
              cachedFix: cached);
          if (a == HeartbeatAction.flushHeld) {
            send(now, cached!);
          } else if (a == HeartbeatAction.refreshFreshest) {
            send(now, cached!);
          }
          if (now != nextFix) continue;
        }
        if (now == nextFix) {
          nextFix = nextFix.add(Duration(
              seconds: fixEverySec + (jitter ? rnd.nextInt(5) : 0)));
          lat += stepM / 111320;
          final SendFix f = fix(now, lat: lat, speed: tier == SendTier.stillIdle ? 0.1 : 1.2);
          cached = f;
          final SendDecision d = SendPolicy.decide(SendInput(
            tier: tier,
            now: now,
            fix: f,
            lastSentAt: lastSentAt,
            lastSentPos: lastPos,
            lastTier: lastTier,
            heldOldestAt: held.isEmpty ? null : held.first,
            heldCount: held.length,
          ));
          lastTier = tier;
          if (d.action == SendAction.hold) {
            held.add(now);
            maxHeld = math.max(maxHeld, held.length);
          } else if (d.action == SendAction.sendNow) {
            send(now, f);
          }
          if (held.isNotEmpty) {
            maxAge = Duration(
                microseconds: math.max(maxAge.inMicroseconds,
                    now.difference(held.first).inMicroseconds));
          }
        }
      }
      return (sends: sends, singles: singles, maxHeld: maxHeld, maxHeldAge: maxAge);
    }

    Duration maxGap(List<DateTime> s, DateTime end) {
      Duration g = Duration.zero;
      for (int k = 1; k < s.length; k++) {
        final Duration d = s[k].difference(s[k - 1]);
        if (d > g) g = d;
      }
      return g;
    }

    test('still 2 h at 60 s fixes: gap <= 6 min', () {
      final r = sim(tier: SendTier.stillIdle, fixEverySec: 60, total: const Duration(hours: 2));
      expect(maxGap(r.sends, t0), lessThanOrEqualTo(const Duration(minutes: 6)));
    });
    test('still 2 h at 180 s fixes: gap < 10 min', () {
      final r = sim(tier: SendTier.stillIdle, fixEverySec: 180, total: const Duration(hours: 2));
      expect(maxGap(r.sends, t0), lessThan(const Duration(minutes: 10)));
    });
    test('still hour makes <= 15 single POSTs', () {
      final r = sim(tier: SendTier.stillIdle, fixEverySec: 60, total: const Duration(hours: 1));
      expect(r.singles, lessThanOrEqualTo(15));
    });
    test('walking stream: held count <= 10, no held older than 90 s', () {
      final r = sim(
          tier: SendTier.walking,
          fixEverySec: 5,
          total: const Duration(hours: 1),
          jitter: true,
          stepM: 5);
      expect(r.maxHeld, lessThanOrEqualTo(10));
      expect(r.maxHeldAge, lessThan(const Duration(seconds: 90)));
      // about 2 requests/min, far below 12
      expect(r.singles, lessThan(60 * 4));
    });
  });
}
