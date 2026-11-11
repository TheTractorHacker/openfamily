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

    test('foreground: leaves drive only after 60 s below 1 m/s', () {
      final TrackingCadence c = TrackingCadence();
      c.onFix(now: at(0), speedMps: 15);
      c.onFix(now: at(1), speedMps: 15);
      expect(c.isDriving, isTrue);
      for (int s = 2; s <= 50; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      expect(c.isDriving, isTrue);
      for (int s = 51; s <= 80; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      expect(c.isDriving, isFalse);
    });

    test('background: a 2 minute jam keeps 1 Hz, drive ends after 3 min, '
        'back to the 60 s profile', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.onFix(now: at(0), speedMps: 15);
      c.onFix(now: at(1), speedMps: 15);
      expect(c.isDriving, isTrue);
      for (int s = 2; s <= 130; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      // A long red light / traffic jam: still driving, still 1 Hz. Leaving
      // drive here used to hand the native side a slow request that activity
      // recognition (STILL) turned into one fix per 15 minutes.
      expect(c.profile(at(130)).tier, CadenceTier.driving);
      expect(c.profile(at(130)).gpsInterval, const Duration(seconds: 1));
      for (int s = 131; s <= 200; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      expect(c.isDriving, isFalse);
      final CadenceProfile p = c.profile(at(200));
      // After the hold the walking evidence also drains (30 s) -> slow.
      for (int s = 201; s <= 240; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      final CadenceProfile after = c.profile(at(240));
      expect(after.tier, CadenceTier.stationary);
      expect(after.gpsInterval, const Duration(seconds: 60));
      expect(p.tier == CadenceTier.walking || p.tier == CadenceTier.stationary,
          isTrue);
    });

    test('background: parked with speed-less fixes still leaves drive', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      for (int s = 0; s <= 4; s++) {
        c.onFix(now: at(s), speedMps: 15, lat: 40 + s * 0.0005, lon: -74);
      }
      expect(c.isDriving, isTrue);
      // Parked: every fix has no speed (-1) and sits at one spot.
      for (int s = 5; s <= 260; s++) {
        c.onFix(now: at(s), speedMps: -1, lat: 40.003, lon: -74);
      }
      expect(c.isDriving, isFalse);
      expect(c.profile(at(260)).tier, isNot(CadenceTier.driving));
    });

    test('background: speed-less fixes that keep moving never end the drive '
        'and never start one', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      for (int s = 0; s <= 4; s++) {
        c.onFix(now: at(s), speedMps: 15, lat: 40 + s * 0.0005, lon: -74);
      }
      for (int s = 5; s <= 260; s++) {
        c.onFix(now: at(s), speedMps: -1, lat: 40.003 + s * 0.0005, lon: -74);
      }
      expect(c.isDriving, isTrue);
      // Steady 11 m/s with no speed on the fixes: the anchor moves only every
      // few fixes, yet the drive must not time out.
      final TrackingCadence e = TrackingCadence()..setBackground(true);
      for (int s = 0; s <= 4; s++) {
        e.onFix(now: at(s), speedMps: 15, lat: 40 + s * 0.0001, lon: -74);
      }
      for (int s = 5; s <= 400; s++) {
        e.onFix(now: at(s), speedMps: -1, lat: 40 + s * 0.0001, lon: -74);
      }
      expect(e.isDriving, isTrue);
      final TrackingCadence d = TrackingCadence()..setBackground(true);
      for (int s = 0; s <= 30; s++) {
        d.onFix(now: at(s), speedMps: -1, lat: 40 + s * 0.0005, lon: -74);
      }
      expect(d.isDriving, isFalse);
    });

    test('background: moving again during the jam stays in drive', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      c.onFix(now: at(0), speedMps: 15);
      for (int s = 1; s <= 150; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      c.onFix(now: at(151), speedMps: 12);
      for (int s = 152; s <= 300; s++) {
        c.onFix(now: at(s), speedMps: 0);
      }
      // The hold restarted at 151 s: 149 s below is not enough.
      expect(c.profile(at(300)).tier, CadenceTier.driving);
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

    test('entering drive from a slow request bypasses the debounce', () {
      final TrackingCadence c = TrackingCadence()..setBackground(true);
      final ProfileApplier a = ProfileApplier(c.config);
      // The slow request was applied 5 s ago (e.g. drive just ended at a light).
      a.markApplied(c.profile(t0), at(0));
      c.onFix(now: at(5), speedMps: 20);
      final CadenceProfile drive = c.profile(at(5));
      expect(drive.tier, CadenceTier.driving);
      expect(a.next(drive, at(5)), isNotNull);
      // Slowing down again is still debounced.
      a.markApplied(drive, at(5));
      expect(a.next((TrackingCadence()..setBackground(true)).profile(at(10)), at(10)),
          isNull);
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

  group('idle tier (battery saver)', () {
    const double lat = 52.0, lon = 4.0;
    TrackingCadence bg() => TrackingCadence()..setBackground(true);

    void still(TrackingCadence c, int fromS, int toS, {double dLon = 0}) {
      for (int s = fromS; s <= toS; s += 60) {
        c.onFix(now: at(s), speedMps: 0, lat: lat, lon: lon + dLon);
      }
    }

    test('stays on the 60 s profile until idleAfter has elapsed', () {
      final TrackingCadence c = bg();
      still(c, 0, 540);
      expect(c.profile(at(540)).tier, CadenceTier.stationary);
    });

    test('after 10 minutes at the same spot: slow, balanced, never off', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      final CadenceProfile p = c.profile(at(600));
      expect(p.tier, CadenceTier.idle);
      expect(p.gpsInterval, const Duration(minutes: 3));
      // No displacement filter: a still phone keeps reporting every 3 min.
      expect(p.distanceFilterM, 0);
      expect(p.highAccuracy, isFalse);
      expect(p.gpsInterval, greaterThan(Duration.zero));
      // The slow profile is still bounded: a post is allowed every 10 s.
      expect(p.minPostInterval, lessThanOrEqualTo(const Duration(minutes: 1)));
    });

    test('foreground never goes idle', () {
      final TrackingCadence c = TrackingCadence();
      still(c, 0, 1200);
      expect(c.profile(at(1200)).tier, CadenceTier.stationary);
    });

    test('GPS jitter inside the radius keeps the timer running', () {
      final TrackingCadence c = bg();
      still(c, 0, 300);
      // ~20 m east.
      still(c, 360, 600, dLon: 0.0003);
      expect(c.profile(at(600)).tier, CadenceTier.idle);
    });

    test('a fix beyond the radius wakes immediately', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      expect(c.profile(at(600)).tier, CadenceTier.idle);
      // ~150 m east.
      c.onFix(now: at(660), speedMps: 0, lat: lat, lon: lon + 0.0022);
      expect(c.profile(at(660)).tier, CadenceTier.stationary);
    });

    test('walking speed wakes immediately', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      c.onFix(now: at(660), speedMps: 2.0, lat: lat, lon: lon);
      expect(c.profile(at(660)).tier, CadenceTier.walking);
    });

    test('driving speed wakes to the 1 Hz profile', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      c.onFix(now: at(660), speedMps: 12, lat: lat, lon: lon + 0.002);
      final CadenceProfile p = c.profile(at(660));
      expect(p.tier, CadenceTier.driving);
      expect(p.gpsInterval, const Duration(seconds: 1));
    });

    test('moving activity state wakes', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      c.onFix(
          now: at(660), speedMps: 0, motionState: 'walking', lat: lat, lon: lon);
      expect(c.profile(at(660)).tier, CadenceTier.walking);
    });

    test('fixes without a position never prove stillness', () {
      final TrackingCadence c = bg();
      for (int s = 0; s <= 1200; s += 60) {
        c.onFix(now: at(s), speedMps: 0);
      }
      expect(c.profile(at(1200)).tier, CadenceTier.stationary);
    });

    test('boost and SOS override idle', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      c.startBoost(const Duration(seconds: 30), at(600));
      expect(c.profile(at(601)).tier, CadenceTier.boosted);
      expect(c.profile(at(640)).tier, CadenceTier.idle);
      c.setSos(true);
      expect(c.profile(at(640)).tier, CadenceTier.sos);
    });

    test('a long gap between idle fixes does not reset idle', () {
      final TrackingCadence c = bg();
      still(c, 0, 600);
      // Next fix only after 3 minutes (the idle interval): stale reset must
      // not fall back to the 60 s profile in between.
      expect(c.profile(at(780)).tier, CadenceTier.idle);
      c.onFix(now: at(780), speedMps: 0, lat: lat, lon: lon);
      expect(c.profile(at(780)).tier, CadenceTier.idle);
    });

    test('applier: idle to driving is applied despite the gap rule only after '
        'minApplyGap, idle itself is not re-asserted', () {
      final TrackingCadence c = bg();
      final ProfileApplier a = ProfileApplier(c.config);
      still(c, 0, 600);
      final CadenceProfile idle = c.profile(at(600));
      a.markApplied(idle, at(600));
      expect(a.next(c.profile(at(600)), at(1200)), isNull);
      c.onFix(now: at(1260), speedMps: 12, lat: lat, lon: lon + 0.002);
      expect(a.next(c.profile(at(1260)), at(1260)), isNotNull);
    });
  });
}
