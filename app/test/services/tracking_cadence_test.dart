import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/tracking_cadence.dart';

final DateTime t0 = DateTime.utc(2026, 1, 1, 12);
DateTime at(int s) => t0.add(Duration(seconds: s));

void main() {
  group('stationary (slow profile)', () {
    test('fresh policy in background = existing 60 s profile', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      final CadenceProfile p = c.profile(t0);
      expect(p.tier, CadenceTier.stationary);
      expect(p.gpsInterval, const Duration(seconds: 60));
      expect(p.distanceFilterM, 0);
    });

    test('fresh policy in foreground = existing 10 m filter / 5 s post', () {
      final CadenceProfile p = TrackingCadence().profile(t0);
      expect(p.tier, CadenceTier.stationary);
      expect(p.distanceFilterM, 10);
      expect(p.minPostInterval, const Duration(seconds: 5));
    });

    test('zero-speed fixes stay slow', () {
      final TrackingCadence c = TrackingCadence();
      for (int i = 0; i < 30; i++) {
        c.onFix(now: at(i * 5), speedMps: 0);
      }
      expect(c.profile(at(150)).tier, CadenceTier.stationary);
    });

    test('GPS speed jitter below walking threshold stays slow', () {
      final TrackingCadence c = TrackingCadence();
      for (int i = 0; i < 20; i++) {
        c.onFix(now: at(i * 5), speedMps: 0.3);
      }
      expect(c.profile(at(100)).tier, CadenceTier.stationary);
    });
  });

  group('drive mode', () {
    test('enters after 2 sustained fixes >= 3 m/s, not on one', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 4);
      expect(c.isDriving, isFalse);
      c.onFix(now: at(1), speedMps: 4);
      expect(c.isDriving, isTrue);
      final CadenceProfile p = c.profile(at(1));
      expect(p.tier, CadenceTier.driving);
      expect(p.gpsInterval, const Duration(seconds: 1));
      expect(p.distanceFilterM, 0);
    });

    test('a single highway-speed fix enters immediately', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.onFix(now: at(0), speedMps: 20);
      expect(c.profile(at(0)).tier, CadenceTier.driving);
    });

    test('never above 1 Hz: gps interval >= 1 s in every tier', () {
      final TrackingCadence c = TrackingCadence();
      c.startBoost(const Duration(seconds: 60), at(0));
      expect(c.profile(at(0)).gpsInterval >= const Duration(seconds: 1), isTrue);
      c.setSos(true);
      expect(c.profile(at(0)).gpsInterval >= const Duration(seconds: 1), isTrue);
    });

    test('red light (< 60 s stopped) keeps drive mode', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 15);
      c.onFix(now: at(1), speedMps: 15);
      for (int s = 2; s <= 50; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      expect(c.profile(at(50)).tier, CadenceTier.driving);
    });

    test('leaves drive only after 60 s below 1 m/s, back to slow profile', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.onFix(now: at(0), speedMps: 15);
      c.onFix(now: at(1), speedMps: 15);
      expect(c.isDriving, isTrue);
      for (int s = 2; s <= 80; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      expect(c.isDriving, isFalse);
      final CadenceProfile p = c.profile(at(80));
      // After the hold the walking evidence also drains (30 s) -> slow.
      for (int s = 81; s <= 120; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      final CadenceProfile after = c.profile(at(120));
      expect(after.tier, CadenceTier.stationary);
      expect(after.gpsInterval, const Duration(seconds: 60));
      expect(p.tier == CadenceTier.walking || p.tier == CadenceTier.stationary,
          isTrue);
    });

    test('slow crawl 1-3 m/s (hysteresis band) keeps drive mode', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 15);
      c.onFix(now: at(1), speedMps: 15);
      for (int s = 2; s <= 200; s++) {
        c.onFix(now: at(s), speedMps: 2);
      }
      expect(c.profile(at(200)).tier, CadenceTier.driving);
    });

    test('no fixes for 2 minutes drops drive mode (stale)', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 15);
      c.onFix(now: at(1), speedMps: 15);
      expect(c.profile(at(60)).tier, CadenceTier.driving);
      expect(c.profile(at(200)).tier, CadenceTier.stationary);
    });
  });

  group('walking', () {
    test('walking speed -> 5 s profile, then back to slow', () {
      final TrackingCadence c = TrackingCadence();
      for (int i = 0; i < 4; i++) {
        c.onFix(now: at(i * 5), speedMps: 1.4);
      }
      final CadenceProfile p = c.profile(at(20));
      expect(p.tier, CadenceTier.walking);
      expect(p.gpsInterval, const Duration(seconds: 5));
      for (int i = 5; i < 20; i++) {
        c.onFix(now: at(i * 5), speedMps: 0);
      }
      expect(c.profile(at(100)).tier, CadenceTier.stationary);
    });

    test('activity-recognition motion state alone promotes to walking probe', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.onFix(now: at(0), speedMps: 0, motionState: 'driving');
      expect(c.profile(at(0)).tier, CadenceTier.walking);
      expect(c.isDriving, isFalse);
    });
  });

  group('boost and SOS', () {
    test('boost = 1 Hz even when stationary, expires, capped at 120 s', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.startBoost(const Duration(seconds: 600), at(0));
      expect(c.profile(at(1)).tier, CadenceTier.boosted);
      expect(c.profile(at(1)).gpsInterval, const Duration(seconds: 1));
      expect(c.profile(at(119)).tier, CadenceTier.boosted);
      expect(c.profile(at(121)).tier, CadenceTier.stationary);
    });

    test('boost never shortens an existing longer boost; 0 ttl ignored', () {
      final TrackingCadence c = TrackingCadence();
      c.startBoost(const Duration(seconds: 100), at(0));
      c.startBoost(const Duration(seconds: 10), at(0));
      expect(c.isBoosted(at(50)), isTrue);
      final TrackingCadence d = TrackingCadence();
      d.startBoost(Duration.zero, at(0));
      expect(d.isBoosted(at(0)), isFalse);
    });

    test('SOS wins over boost and drive; 2 s post preserved', () {
      final TrackingCadence c = TrackingCadence();
      c.startBoost(const Duration(seconds: 60), at(0));
      c.setSos(true);
      final CadenceProfile p = c.profile(at(1));
      expect(p.tier, CadenceTier.sos);
      expect(p.minPostInterval, const Duration(seconds: 2));
      c.setSos(false);
      expect(c.profile(at(1)).tier, CadenceTier.boosted);
    });
  });

  group('battery', () {
    test('< 15% not charging backs off walking and driving', () {
      final TrackingCadence c = TrackingCadence();
      c.setBattery(10);
      c.onFix(now: at(0), speedMps: 20);
      final CadenceProfile d = c.profile(at(0));
      expect(d.tier, CadenceTier.driving);
      expect(d.lowBatteryBackoff, isTrue);
      expect(d.gpsInterval, const Duration(seconds: 5));
    });

    test('charging or boosted or SOS is not backed off', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 20);
      c.setBattery(10, charging: true);
      expect(c.profile(at(0)).gpsInterval, const Duration(seconds: 1));
      c.setBattery(10);
      c.startBoost(const Duration(seconds: 30), at(0));
      expect(c.profile(at(0)).gpsInterval, const Duration(seconds: 1));
      expect(c.profile(at(0)).lowBatteryBackoff, isFalse);
      c.setSos(true);
      expect(c.profile(at(0)).tier, CadenceTier.sos);
    });

    test('stationary profile is unchanged by low battery', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.setBattery(5);
      expect(c.profile(t0).gpsInterval, const Duration(seconds: 60));
    });
  });

  group('ProfileApplier debounce', () {
    CadenceProfile slow(TrackingCadence c, DateTime n) => c.profile(n);

    test('never changes the GPS request more often than every 20 s', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      final ProfileApplier a = ProfileApplier(c.config);
      a.markApplied(c.profile(t0), t0.subtract(const Duration(minutes: 1)));
      // Enter drive at +1 s: first change is allowed (last apply was long ago).
      c.onFix(now: at(1), speedMps: 20);
      final CadenceProfile drive = c.profile(at(1));
      expect(a.next(drive, at(1)), isNotNull);
      a.markApplied(drive, at(1));
      // Flap to walking/stationary and back within 20 s: suppressed.
      final CadenceProfile slowP = slow(TrackingCadence()..setBackground(true), at(5));
      expect(a.next(slowP, at(5)), isNull);
      expect(a.next(slowP, at(20)), isNull);
      expect(a.next(slowP, at(22)), isNotNull);
    });

    test('boost and SOS speed-ups bypass the debounce', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      final ProfileApplier a = ProfileApplier(c.config);
      a.markApplied(c.profile(t0), t0);
      c.startBoost(const Duration(seconds: 60), at(2));
      expect(a.next(c.profile(at(2)), at(2)), isNotNull);
    });

    test('post-gate-only differences never restart the GPS source', () {
      final TrackingCadence c = TrackingCadence();
      final ProfileApplier a = ProfileApplier(c.config);
      final CadenceProfile p = c.profile(t0);
      a.markApplied(p, t0);
      expect(a.next(c.profile(at(100)), at(100)), isNull);
    });

    test('non-stationary profile is re-asserted after 5 min', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 20);
      final ProfileApplier a = ProfileApplier(c.config);
      final CadenceProfile d = c.profile(at(0));
      a.markApplied(d, at(0));
      c.onFix(now: at(299), speedMps: 20);
      expect(a.next(c.profile(at(299)), at(299)), isNull);
      c.onFix(now: at(301), speedMps: 20);
      expect(a.next(c.profile(at(301)), at(301)), isNotNull);
    });
  });
}
