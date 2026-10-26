import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/fix_quality.dart';
import 'package:openfamily/services/live_boost.dart';
import 'package:openfamily/services/tracking_cadence.dart';

final DateTime t0 = DateTime.utc(2026, 1, 1, 12);

void main() {
  group('speedFields', () {
    test('sends 0 when GPS says 0 and accuracy is good', () {
      final Map<String, dynamic> m =
          speedFields(speedMps: 0, speedAccuracyMps: 0, accuracyM: 5);
      expect(m['speed_mps'], 0);
      expect(m.containsKey('speed_accuracy'), isFalse);
    });

    test('omits 0 when accuracy is poor or unknown', () {
      expect(speedFields(speedMps: 0, speedAccuracyMps: 0, accuracyM: 80),
          isEmpty);
      expect(speedFields(speedMps: 0, speedAccuracyMps: 0, accuracyM: 0),
          isEmpty);
    });

    test('sends positive speed and speed_accuracy', () {
      final Map<String, dynamic> m = speedFields(
          speedMps: 13.4, speedAccuracyMps: 0.8, accuracyM: 90);
      expect(m['speed_mps'], 13.4);
      expect(m['speed_accuracy'], 0.8);
    });

    test('drops negative, NaN and absurd speeds', () {
      expect(speedFields(speedMps: -1, speedAccuracyMps: 0, accuracyM: 5),
          isEmpty);
      expect(
          speedFields(speedMps: double.nan, speedAccuracyMps: 0, accuracyM: 5),
          isEmpty);
      expect(speedFields(speedMps: 500, speedAccuracyMps: 0, accuracyM: 5),
          isEmpty);
    });
  });

  group('FixQualityFilter', () {
    FixVerdict check(FixQualityFilter f, int s,
        {double lat = 10, double lon = 10, double acc = 5, double? speed}) {
      return f.check(
        ts: t0.add(Duration(seconds: s)),
        lat: lat,
        lon: lon,
        accuracyM: acc,
        speedMps: speed,
      );
    }

    test('accepts a normal fix', () {
      expect(check(FixQualityFilter(), 0), FixVerdict.ok);
    });

    test('rejects accuracy > 50 m while moving, accepts it when stationary', () {
      final FixQualityFilter f = FixQualityFilter();
      expect(check(f, 0, acc: 80, speed: 12), FixVerdict.poorAccuracy);
      expect(check(f, 1, acc: 80, speed: 0), FixVerdict.ok);
    });

    test('rejects a jump implying > 70 m/s', () {
      final FixQualityFilter f = FixQualityFilter();
      expect(check(f, 0), FixVerdict.ok);
      // ~1.1 km north in 2 s.
      expect(check(f, 2, lat: 10.01), FixVerdict.jump);
    });

    test('accepts realistic highway movement (30 m/s)', () {
      final FixQualityFilter f = FixQualityFilter();
      expect(check(f, 0), FixVerdict.ok);
      // 30 m in 1 s ~ 0.00027 deg lat.
      expect(check(f, 1, lat: 10.00027), FixVerdict.ok);
    });

    test('persistent relocation is re-baselined after 3 rejects', () {
      final FixQualityFilter f = FixQualityFilter();
      expect(check(f, 0), FixVerdict.ok);
      expect(check(f, 2, lat: 11), FixVerdict.jump);
      expect(check(f, 3, lat: 11), FixVerdict.jump);
      expect(check(f, 4, lat: 11), FixVerdict.jump);
      expect(check(f, 5, lat: 11), FixVerdict.ok);
      expect(check(f, 6, lat: 11), FixVerdict.ok);
    });

    test('rejects timestamps not newer than the last accepted or sent', () {
      final FixQualityFilter f = FixQualityFilter();
      expect(check(f, 10), FixVerdict.ok);
      expect(check(f, 10), FixVerdict.stale);
      expect(check(f, 5), FixVerdict.stale);
      expect(
        f.check(
          ts: t0.add(const Duration(seconds: 20)),
          lat: 10,
          lon: 10,
          accuracyM: 5,
          lastSentTs: t0.add(const Duration(seconds: 30)),
        ),
        FixVerdict.stale,
      );
    });
  });

  group('LiveBoost parsing', () {
    test('parses live_boost and caps ttl at 120 s', () {
      expect(LiveBoost.parseCommand('{"type":"live_boost","ttl_s":60}'),
          const Duration(seconds: 60));
      expect(LiveBoost.parseCommand('{"type":"live_boost","ttl_s":9999}'),
          const Duration(seconds: 120));
    });

    test('tolerant: missing/invalid ttl uses default, garbage is null', () {
      expect(LiveBoost.parseCommand('{"type":"live_boost"}'),
          const Duration(seconds: 60));
      expect(LiveBoost.parseCommand('{"type":"live_boost","ttl_s":"x"}'),
          const Duration(seconds: 60));
      expect(LiveBoost.parseCommand('{"type":"live_boost","ttl_s":-5}'),
          const Duration(seconds: 60));
      expect(LiveBoost.parseCommand('not json'), isNull);
      expect(LiveBoost.parseCommand('{"type":"location_request"}'), isNull);
      expect(LiveBoost.parseCommand('[1]'), isNull);
    });

    test('responseIsLive handles map, string, junk', () {
      expect(LiveBoost.responseIsLive(<String, dynamic>{'live': true}), isTrue);
      expect(LiveBoost.responseIsLive('{"status":"ok","live":true}'), isTrue);
      expect(LiveBoost.responseIsLive(<String, dynamic>{'live': false}), isFalse);
      expect(LiveBoost.responseIsLive(<String, dynamic>{'live': 'yes'}), isFalse);
      expect(LiveBoost.responseIsLive(null), isFalse);
      expect(LiveBoost.responseIsLive('oops'), isFalse);
      expect(LiveBoost.responseIsLive(''), isFalse);
    });

    test('apply boosts registered policies and fires the hook', () async {
      final TrackingCadence c = TrackingCadence();
      int hooks = 0;
      LiveBoost.register(c, onBoost: () => hooks++);
      final DateTime now = DateTime.now().toUtc();
      expect(await LiveBoost.apply(const Duration(seconds: 500), now: now),
          isTrue);
      expect(c.isBoosted(now.add(const Duration(seconds: 100))), isTrue);
      expect(c.isBoosted(now.add(const Duration(seconds: 125))), isFalse);
      expect(hooks, 1);
      LiveBoost.unregister(c);
    });
  });
}
