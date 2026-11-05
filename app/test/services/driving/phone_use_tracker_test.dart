import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/driving_config.dart';
import 'package:openfamily/services/driving/driving_event.dart';
import 'package:openfamily/services/driving/handling_analyzer.dart';
import 'package:openfamily/services/driving/phone_context.dart';
import 'package:openfamily/services/driving/phone_use_tracker.dart';

/// Scenario driver. Times are in seconds from the start of the drive; the
/// vehicle is moving from t=0 unless a scenario changes the speed.
class _Drive {
  _Drive([PhoneUseConfig c = const PhoneUseConfig()])
      : t = PhoneUseTracker(config: c) {
    t.begin(0);
  }

  final PhoneUseTracker t;
  double speed = 20;
  int now = 0;

  int ms(num s) => (s * 1000).round();

  /// Advances to [toS], one GPS fix per second at the current [speed], and a
  /// handling window every 2 s with the verdict from [handledAt].
  void run(int toS, {bool Function(int s)? handledAt}) {
    while (now < toS) {
      now++;
      t.onSpeed(ms(now), speed, 40.0, -75.0);
      if (now.isEven && handledAt != null) {
        final bool h = handledAt(now);
        t.onHandling(HandlingWindow(
            startMs: ms(now - 2),
            endMs: ms(now),
            score: h ? 2 : 0.1,
            handled: h));
      } else if (now.isEven) {
        t.onHandling(HandlingWindow(
            startMs: ms(now - 2), endMs: ms(now), score: 0.1, handled: false));
      }
    }
  }

  void screen(ScreenSignal s) => t.onScreen(ms(now), s);
  void unlock() {
    t.onScreen(ms(now), ScreenSignal.screenOn);
    t.onScreen(ms(now), ScreenSignal.userPresent);
  }

  void ctx(PhoneContext c) => t.onContext(c.copyWith(tMs: ms(now)));

  List<DrivingEvent> end() {
    t.finish(ms(now + 1));
    return t.takeEvents();
  }
}

PhoneContext call(AudioRoute r, {Proximity p = Proximity.far, bool car = false}) =>
    PhoneContext(
        proximity: p, callMode: CallMode.call, route: r, carMode: car);

void main() {
  group('screen use', () {
    test('texting: unlock, handled phone, screen off is one event', () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(48, handledAt: (int s) => true);
      d.screen(ScreenSignal.screenOff);
      d.run(60);
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(1));
      expect(e.single.kind, DrivingEventKind.phoneUse);
      expect(e.single.magnitude, inInclusiveRange(16, 22));
      expect(e.single.maxSpeedMps, 20);
      expect(e.single.confidence, greaterThan(0.7));
      expect(e.single.activity, 'screen');
      expect(e.single.lat, 40.0);
    });

    test('mounted navigation: a screen already on and stable never counts', () {
      final _Drive d = _Drive();
      d.t.onScreen(0, ScreenSignal.screenOn); // lit before the drive
      d.run(300);
      expect(d.end(), isEmpty);
    });

    test('navigation that was unlocked once counts only the unlock grace', () {
      final _Drive d = _Drive()..run(30);
      d.unlock(); // driver taps the mounted phone, then it stays still
      d.run(300); // lit, never handled
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(1));
      expect(e.single.magnitude, lessThanOrEqualTo(12.5));
      expect(e.single.confidence, lessThan(0.5)); // flagged as likely false
    });

    test('screen already on before the drive counts when it is handled', () {
      final _Drive d = _Drive();
      d.t.onScreen(0, ScreenSignal.screenOn); // no unlock event at all
      d.run(30);
      d.run(46, handledAt: (int s) => true);
      d.run(80);
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(1));
      expect(e.single.magnitude, greaterThan(10));
    });

    test('a notification wake without handling or unlock does not count', () {
      final _Drive d = _Drive()..run(30);
      d.screen(ScreenSignal.screenOn);
      d.run(38);
      d.screen(ScreenSignal.screenOff);
      d.run(60);
      expect(d.end(), isEmpty);
    });

    test('unlock inside a pocket or bag (proximity near, no handling)', () {
      final _Drive d = _Drive()..run(30);
      d.ctx(const PhoneContext(proximity: Proximity.near));
      d.unlock();
      d.run(60);
      d.screen(ScreenSignal.screenOff);
      d.run(70);
      expect(d.end(), isEmpty);
    });

    test('a very short tap is below the minimum', () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(31);
      d.screen(ScreenSignal.screenOff);
      d.run(60);
      expect(d.end(), isEmpty);
    });

    test('no motion data at all: falls back to the unlocked screen', () {
      final PhoneUseTracker t = PhoneUseTracker()..begin(0);
      for (int s = 1; s <= 30; s++) {
        t.onSpeed(s * 1000, 20, null, null);
      }
      t.onScreen(30000, ScreenSignal.userPresent);
      for (int s = 31; s <= 80; s++) {
        t.onSpeed(s * 1000, 20, null, null);
      }
      t.onScreen(80000, ScreenSignal.screenOff);
      t.finish(100000);
      final List<DrivingEvent> e = t.takeEvents();
      expect(e, hasLength(1));
      expect(e.single.magnitude, greaterThanOrEqualTo(40));
    });
  });

  group('speed gating', () {
    test('a red light neither counts nor splits the event', () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(40, handledAt: (int s) => true);
      d.speed = 0; // red light for 5 s (< stop grace)
      d.run(45, handledAt: (int s) => true);
      d.speed = 15;
      d.run(60, handledAt: (int s) => true);
      d.screen(ScreenSignal.screenOff);
      d.run(80);
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(1));
      // ~30 s of span, minus ~5 s standing still.
      final double span = (e.single.endedAtMs - e.single.startedAtMs) / 1000;
      expect(span, greaterThan(28));
      expect(e.single.magnitude, lessThanOrEqualTo(span - 3));
      expect(e.single.magnitude, greaterThan(20));
    });

    test('a long stop closes the event; the stationary time is not counted',
        () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(45, handledAt: (int s) => true);
      d.speed = 0;
      d.run(120, handledAt: (int s) => true); // phone still being handled
      d.speed = 20;
      d.run(140, handledAt: (int s) => true);
      d.screen(ScreenSignal.screenOff);
      final List<DrivingEvent> e = d.end();
      // Second event after the green light: separate, and no stopped seconds
      // in either.
      expect(e.length, 2);
      for (final DrivingEvent x in e) {
        expect(x.magnitude, lessThan(30));
      }
      expect(e.first.endedAtMs, lessThan(60000));
    });

    test('use while parked or crawling is never counted', () {
      final _Drive d = _Drive();
      d.speed = 0;
      d.run(30);
      d.unlock();
      d.run(120, handledAt: (int s) => true);
      expect(d.end(), isEmpty);
      final _Drive c = _Drive();
      c.speed = 4; // walking/creeping pace never reaches the start speed
      c.run(10);
      c.unlock();
      c.run(80, handledAt: (int s) => true);
      expect(c.end(), isEmpty);
    });

    test('the first and last seconds of a drive are ignored', () {
      final _Drive d = _Drive();
      d.unlock(); // phone being placed in the mount right at the start
      d.run(8, handledAt: (int s) => true);
      d.screen(ScreenSignal.screenOff);
      d.run(50);
      d.unlock(); // phone grabbed from the mount while pulling in
      d.run(58, handledAt: (int s) => true);
      d.speed = 0; // parked at 58 s
      d.run(70);
      expect(d.end(), isEmpty);
    });

    test('use shortly before the final stop loses only the last seconds', () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(70, handledAt: (int s) => true);
      d.speed = 0;
      d.run(90);
      d.screen(ScreenSignal.screenOff);
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(1));
      // Counted 30..60 (last 10 s of the drive trimmed): ~25-30 s.
      expect(e.single.magnitude, inInclusiveRange(20, 31));
      expect(e.single.endedAtMs, lessThanOrEqualTo(61000));
    });
  });

  group('merging, limits and severity', () {
    test('interactions less than 10 s apart merge; farther apart do not', () {
      final _Drive d = _Drive()..run(30);
      for (final List<int> g in <List<int>>[
        <int>[30, 38],
        <int>[44, 52], // 6 s later: merged
        <int>[80, 88], // 28 s later: separate
      ]) {
        d.run(g[0]);
        d.unlock();
        d.run(g[1], handledAt: (int s) => true);
        d.screen(ScreenSignal.screenOff);
      }
      d.run(100);
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(2));
      // Severity is seconds of interaction, not the span of the merged event.
      final double span0 = (e[0].endedAtMs - e[0].startedAtMs) / 1000;
      expect(e[0].magnitude, lessThan(span0));
      expect(e[0].magnitude, greaterThan(10));
    });

    test('a continuous interaction is split into events of <= 180 s', () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(500, handledAt: (int s) => true);
      d.screen(ScreenSignal.screenOff);
      final List<DrivingEvent> e = d.end();
      expect(e.length, greaterThanOrEqualTo(3));
      for (final DrivingEvent x in e) {
        expect((x.endedAtMs - x.startedAtMs) / 1000, lessThanOrEqualTo(180));
        expect(x.magnitude, lessThanOrEqualTo(180));
      }
    });

    test('repeats are capped per drive', () {
      final _Drive d = _Drive()..run(30);
      int at = 30;
      for (int i = 0; i < 20; i++) {
        d.run(at);
        d.unlock();
        d.run(at + 8, handledAt: (int s) => true);
        d.screen(ScreenSignal.screenOff);
        at += 40;
        d.run(at);
      }
      final List<DrivingEvent> e = d.end();
      expect(e.length, const PhoneUseConfig().maxEventsPerDrive);
    });

    test('events serialize with the optional fields', () {
      final _Drive d = _Drive()..run(30);
      d.unlock();
      d.run(60, handledAt: (int s) => true);
      d.screen(ScreenSignal.screenOff);
      final Map<String, dynamic> j = d.end().single.toJson();
      expect(j['kind'], 'phone_use');
      expect(j['max_speed_mps'], 20.0);
      expect(j['confidence'], isA<double>());
      expect(j['activity'], 'screen');
      // Other kinds keep the old, smaller shape.
      expect(
          const DrivingEvent(
                  kind: DrivingEventKind.hardBrake,
                  startedAtMs: 0,
                  endedAtMs: 1,
                  magnitude: 4)
              .toJson()
              .keys,
          isNot(contains('confidence')));
    });
  });

  group('calls', () {
    test('a handset call at the ear counts', () {
      final _Drive d = _Drive()..run(30);
      d.ctx(call(AudioRoute.earpiece, p: Proximity.near));
      d.run(70);
      d.ctx(const PhoneContext());
      d.run(80);
      final List<DrivingEvent> e = d.end();
      expect(e, hasLength(1));
      expect(e.single.activity, 'call');
      expect(e.single.magnitude, inInclusiveRange(35, 41));
      expect(e.single.confidence, greaterThan(0.8));
    });

    test('a call over car Bluetooth is hands-free and does not count', () {
      final _Drive d = _Drive()..run(30);
      d.ctx(call(AudioRoute.bluetooth));
      d.run(120);
      d.ctx(const PhoneContext());
      d.run(130);
      expect(d.end(), isEmpty);
    });

    test('Android Auto / car mode and a wired headset are hands-free', () {
      for (final PhoneContext c in <PhoneContext>[
        call(AudioRoute.earpiece, car: true),
        call(AudioRoute.car),
        call(AudioRoute.wired),
      ]) {
        final _Drive d = _Drive()..run(30);
        d.ctx(c);
        d.run(100);
        expect(d.end(), isEmpty, reason: '$c');
      }
    });

    test('speakerphone counts only while the phone is handled', () {
      final _Drive still = _Drive()..run(30);
      still.ctx(call(AudioRoute.speaker));
      still.run(100);
      expect(still.end(), isEmpty);

      final _Drive held = _Drive()..run(30);
      held.ctx(call(AudioRoute.speaker));
      held.run(70, handledAt: (int s) => s >= 40 && s <= 60);
      final List<DrivingEvent> e = held.end();
      expect(e, hasLength(1));
      expect(e.single.activity, 'call');
    });

    test('a call whose route is unknown counts only at the ear', () {
      final _Drive d = _Drive()..run(30);
      d.ctx(call(AudioRoute.unknown));
      d.run(100);
      expect(d.end(), isEmpty);
      final _Drive e2 = _Drive()..run(30);
      e2.ctx(call(AudioRoute.unknown, p: Proximity.near));
      e2.run(100);
      expect(e2.end(), hasLength(1));
    });

    test('a hands-free call while the screen sits idle does not count', () {
      final _Drive d = _Drive();
      d.t.onScreen(0, ScreenSignal.screenOn);
      d.run(30);
      d.ctx(call(AudioRoute.bluetooth));
      d.run(200);
      expect(d.end(), isEmpty);
    });
  });
}
