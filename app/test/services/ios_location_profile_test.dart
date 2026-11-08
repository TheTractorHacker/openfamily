import 'dart:io';

import 'package:background_locator_2/keys.dart';
import 'package:background_locator_2/location_dto.dart';
import 'package:background_locator_2/settings/ios_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/ios_location_profile.dart';
import 'package:openfamily/services/tracking_cadence.dart';

final DateTime t0 = DateTime.utc(2026, 1, 1, 12);
DateTime at(int s) => t0.add(Duration(seconds: s));

const double lat = 52.0, lon = 4.0;

/// About 150 m east of [lon] at latitude 52.
const double dLon150 = 0.0022;

CadenceProfile profileOf(CadenceTier tier, {bool lowBattery = false}) =>
    CadenceProfile(
      tier: tier,
      gpsInterval: const Duration(seconds: 5),
      distanceFilterM: 0,
      minPostInterval: const Duration(seconds: 5),
      highAccuracy: true,
      lowBatteryBackoff: lowBattery,
    );

void main() {
  group('profile to Core Location request', () {
    test('SOS and live boost: best accuracy, (almost) every fix', () {
      final IOSLocationRequest sos = iosRequestFor(profileOf(CadenceTier.sos));
      expect(sos.accuracy, IOSAccuracy.best);
      expect(sos.distanceFilterM, 0);
      expect(sos.isStill, isFalse);
      final IOSLocationRequest boost =
          iosRequestFor(profileOf(CadenceTier.boosted));
      expect(boost.accuracy, IOSAccuracy.best);
      expect(boost.distanceFilterM, 5);
      expect(boost.isStill, isFalse);
    });

    test('driving: best accuracy, automotive, 10 m filter', () {
      final IOSLocationRequest r = iosRequestFor(profileOf(CadenceTier.driving));
      expect(r.accuracy, IOSAccuracy.best);
      expect(r.activityType, IOSActivityType.automotiveNavigation);
      expect(r.distanceFilterM, 10);
      expect(r.isStill, isFalse);
    });

    test('walking: nearest ten meters, fitness, 15 m filter', () {
      final IOSLocationRequest r = iosRequestFor(profileOf(CadenceTier.walking));
      expect(r.accuracy, IOSAccuracy.nearestTenMeters);
      expect(r.activityType, IOSActivityType.fitness);
      expect(r.distanceFilterM, inInclusiveRange(10, 25));
    });

    test('low battery relaxes walking and driving', () {
      final IOSLocationRequest w =
          iosRequestFor(profileOf(CadenceTier.walking, lowBattery: true));
      expect(w.accuracy, IOSAccuracy.nearestTenMeters);
      expect(w.distanceFilterM, 25);
      final IOSLocationRequest d =
          iosRequestFor(profileOf(CadenceTier.driving, lowBattery: true));
      expect(d.accuracy, IOSAccuracy.nearestTenMeters);
      expect(d.distanceFilterM, 25);
      expect(d.activityType, IOSActivityType.automotiveNavigation);
    });

    test('stationary = the slow request (registration and native wake-up)', () {
      final IOSLocationRequest r =
          iosRequestFor(profileOf(CadenceTier.stationary));
      expect(r, iosSlowRequest());
      expect(r.accuracy, IOSAccuracy.nearestTenMeters);
      expect(r.distanceFilterM, 25);
      expect(r.isStill, isFalse);
    });

    test('idle = still: 3 km accuracy (no GPS), 200 m filter, 150 m region', () {
      final IOSLocationRequest r = iosRequestFor(profileOf(CadenceTier.idle));
      expect(r.accuracy, IOSAccuracy.threeKilometers);
      expect(r.distanceFilterM, 200);
      expect(r.stillRegionRadiusM, 150);
      expect(r.isStill, isTrue);
    });

    test('only the idle tier arms the still region', () {
      for (final CadenceTier t in CadenceTier.values) {
        expect(iosRequestFor(profileOf(t)).isStill, t == CadenceTier.idle,
            reason: t.name);
      }
    });

    test('registration settings equal the slow request', () {
      final IOSSettings s = iosRegistrationSettings();
      // BALANCED (2) is kCLLocationAccuracyNearestTenMeters in Util.getAccuracy.
      expect(s.accuracy.value, 2);
      expect(iosSlowRequest().accuracy, IOSAccuracy.nearestTenMeters);
      expect(s.distanceFilter, iosSlowRequest().distanceFilterM);
      expect(s.showsBackgroundLocationIndicator, isTrue);
      expect(s.stopWithTerminate, isFalse);
    });
  });

  group('state machine on iOS (fixes only on movement)', () {
    TrackingCadence bg() => TrackingCadence()..setBackground(true);

    test('one fix, then silence: the heartbeat tick reaches still after 10 min',
        () {
      final TrackingCadence c = bg();
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      expect(iosRequestFor(c.profile(at(300))).isStill, isFalse);
      // 5 minute native heartbeat: 600 s is the second tick.
      expect(c.profile(at(600)).tier, CadenceTier.idle);
      expect(iosRequestFor(c.profile(at(600))).isStill, isTrue);
    });

    test('walking speed leaves still at once', () {
      final TrackingCadence c = bg();
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      expect(c.profile(at(600)).tier, CadenceTier.idle);
      c.onFix(now: at(610), speedMps: 1.4, lat: lat, lon: lon + 0.0003);
      expect(c.profile(at(610)).tier, CadenceTier.walking);
      expect(iosRequestFor(c.profile(at(610))).accuracy,
          IOSAccuracy.nearestTenMeters);
    });

    test('a good fix beyond the idle radius leaves still', () {
      final TrackingCadence c = bg();
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      expect(c.profile(at(600)).tier, CadenceTier.idle);
      c.onFix(now: at(700), lat: lat, lon: lon + dLon150);
      expect(c.profile(at(700)).tier, CadenceTier.stationary);
      expect(iosRequestFor(c.profile(at(700))), iosSlowRequest());
    });

    test('driving speed jumps straight to the driving request', () {
      final TrackingCadence c = bg();
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      expect(c.profile(at(600)).tier, CadenceTier.idle);
      c.onFix(now: at(700), speedMps: 12, lat: lat, lon: lon + dLon150);
      expect(iosRequestFor(c.profile(at(700))).activityType,
          IOSActivityType.automotiveNavigation);
    });

    test('onWake forgets the anchor: still needs another 10 min', () {
      final TrackingCadence c = bg();
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      expect(c.profile(at(600)).tier, CadenceTier.idle);
      c.onWake(at(700));
      expect(c.distanceFromIdleAnchor(lat, lon), isNull);
      expect(c.profile(at(700)).tier, CadenceTier.stationary);
      // Same spot again (a false region exit): idle only 10 min later.
      c.onFix(now: at(710), speedMps: 0, lat: lat, lon: lon);
      expect(c.profile(at(1200)).tier, CadenceTier.stationary);
      expect(c.profile(at(1310)).tier, CadenceTier.idle);
    });

    test('distanceFromIdleAnchor measures from the anchor', () {
      final TrackingCadence c = bg();
      expect(c.distanceFromIdleAnchor(lat, lon), isNull);
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      final double d = c.distanceFromIdleAnchor(lat, lon + dLon150)!;
      expect(d, closeTo(150, 5));
    });

    test('applier: still is applied once (no re-assert), wake after it is', () {
      final TrackingCadence c = bg();
      final ProfileApplier a = ProfileApplier(c.config);
      c.onFix(now: at(0), speedMps: 0, lat: lat, lon: lon);
      a.markApplied(c.profile(at(0)), at(0));
      final CadenceProfile idle = c.profile(at(600));
      expect(a.next(idle, at(600)), isNotNull);
      a.markApplied(idle, at(600));
      expect(a.next(c.profile(at(4000)), at(4000)), isNull);
      // Native reset (region exit): the service resets the applier; the
      // current profile goes out at once.
      a.reset();
      c.onWake(at(4000));
      final CadenceProfile? p = a.next(c.profile(at(4000)), at(4000));
      expect(p, isNotNull);
      expect(iosRequestFor(p!), iosSlowRequest());
    });
  });

  group('coarse fixes while still', () {
    test('good fixes always pass', () {
      expect(
        iosFixDecision(
            stillRequestActive: true, nativeReset: false, accuracyM: 30),
        IosFixDecision.accept,
      );
      expect(
        iosFixDecision(
            stillRequestActive: true, nativeReset: true, accuracyM: 65),
        IosFixDecision.accept,
      );
    });

    test('coarse fixes outside still mode keep today\'s behaviour', () {
      expect(
        iosFixDecision(
            stillRequestActive: false, nativeReset: false, accuracyM: 1500),
        IosFixDecision.accept,
      );
    });

    test('coarse fix near the anchor while still: dropped, no wake', () {
      expect(
        iosFixDecision(
          stillRequestActive: true,
          nativeReset: false,
          accuracyM: 1000,
          distanceFromAnchorM: 600,
        ),
        IosFixDecision.drop,
      );
      expect(
        iosFixDecision(
            stillRequestActive: true, nativeReset: false, accuracyM: -1),
        IosFixDecision.drop,
      );
    });

    test('coarse fix whose error circle is outside the region: wake', () {
      expect(
        iosFixDecision(
          stillRequestActive: true,
          nativeReset: false,
          accuracyM: 500,
          distanceFromAnchorM: 2000,
        ),
        IosFixDecision.dropAndWake,
      );
    });

    test('coarse first fix after a native wake-up: not posted, still wakes', () {
      expect(
        iosFixDecision(
            stillRequestActive: false, nativeReset: true, accuracyM: 3000),
        IosFixDecision.dropAndWake,
      );
    });
  });

  group('channel contract with the native plugin', () {
    test('request map keys and codes', () {
      final Map<String, dynamic> m =
          iosRequestFor(profileOf(CadenceTier.idle)).toMap();
      expect(m, <String, dynamic>{
        Keys.ARG_REQUEST_IOS_ACCURACY: 0,
        Keys.ARG_REQUEST_IOS_DISTANCE_FILTER: 200.0,
        Keys.ARG_REQUEST_IOS_ACTIVITY_TYPE: 0,
        Keys.ARG_REQUEST_IOS_STILL_REGION_M: 150.0,
      });
    });

    test('nativeReset is read from the location map (absent = false)', () {
      final Map<String, dynamic> base = <String, dynamic>{
        Keys.ARG_LATITUDE: lat,
        Keys.ARG_LONGITUDE: lon,
        Keys.ARG_ACCURACY: 10.0,
        Keys.ARG_ALTITUDE: 0.0,
        Keys.ARG_SPEED: 0.0,
        Keys.ARG_SPEED_ACCURACY: 0.0,
        Keys.ARG_HEADING: 0.0,
        Keys.ARG_TIME: 0.0,
      };
      expect(LocationDto.fromJson(base).nativeReset, isFalse);
      expect(
        LocationDto.fromJson(<String, dynamic>{
          ...base,
          Keys.ARG_NATIVE_RESET: true,
        }).nativeReset,
        isTrue,
      );
    });

    // The Objective-C switch statements must translate the Dart codes
    // one-to-one. Parse them from the source so a drift fails here (the
    // native code cannot be compiled on Linux).
    Map<int, String> switchCases(String source, String selector) {
      final int start = source.indexOf(selector);
      expect(start, greaterThanOrEqualTo(0), reason: selector);
      final int end = source.indexOf('\n}', start);
      final String body = source.substring(start, end);
      final Map<int, String> out = <int, String>{};
      for (final RegExpMatch m in RegExp(r'case (\d+):\s*return (\w+);')
          .allMatches(body)) {
        out[int.parse(m.group(1)!)] = m.group(2)!;
      }
      return out;
    }

    final String util = File(
            'packages/background_locator_2/ios/Classes/Utils/Util.m')
        .readAsStringSync();

    test('IOSAccuracy codes match +[Util requestAccuracy:]', () {
      const Map<IOSAccuracy, String> expected = <IOSAccuracy, String>{
        IOSAccuracy.threeKilometers: 'kCLLocationAccuracyThreeKilometers',
        IOSAccuracy.kilometer: 'kCLLocationAccuracyKilometer',
        IOSAccuracy.hundredMeters: 'kCLLocationAccuracyHundredMeters',
        IOSAccuracy.nearestTenMeters: 'kCLLocationAccuracyNearestTenMeters',
        IOSAccuracy.best: 'kCLLocationAccuracyBest',
        IOSAccuracy.bestForNavigation: 'kCLLocationAccuracyBestForNavigation',
      };
      final Map<int, String> cases =
          switchCases(util, '+ (CLLocationAccuracy) requestAccuracy:');
      expect(cases.length, IOSAccuracy.values.length);
      for (final IOSAccuracy a in IOSAccuracy.values) {
        expect(cases[a.code], expected[a], reason: a.name);
      }
    });

    test('IOSActivityType codes match +[Util activityType:]', () {
      final Map<int, String> cases =
          switchCases(util, '+ (CLActivityType) activityType:');
      expect(cases[IOSActivityType.automotiveNavigation.code],
          'CLActivityTypeAutomotiveNavigation');
      expect(cases[IOSActivityType.fitness.code], 'CLActivityTypeFitness');
      expect(cases[IOSActivityType.otherNavigation.code],
          'CLActivityTypeOtherNavigation');
      // other (0) is the default branch.
      expect(cases.containsKey(IOSActivityType.other.code), isFalse);
      expect(util, contains('return CLActivityTypeOther;'));
    });

    test('channel keys match Globals.m', () {
      final String globals = File(
              'packages/background_locator_2/ios/Classes/Globals.m')
          .readAsStringSync();
      for (final String key in <String>[
        Keys.METHOD_PLUGIN_UPDATE_LOCATION_REQUEST,
        Keys.ARG_REQUEST_IOS_ACCURACY,
        Keys.ARG_REQUEST_IOS_DISTANCE_FILTER,
        Keys.ARG_REQUEST_IOS_ACTIVITY_TYPE,
        Keys.ARG_REQUEST_IOS_STILL_REGION_M,
        Keys.ARG_NATIVE_RESET,
        Keys.ARG_HEARTBEAT_CALLBACK,
        Keys.BCM_SEND_HEARTBEAT,
      ]) {
        expect(globals, contains('@"$key"'), reason: key);
      }
    });
  });
}
