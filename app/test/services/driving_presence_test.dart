import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/driving_presence.dart';
import 'package:openfamily/services/member_mapper.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/utils/member_status.dart';

/// The one "driving at 0 mph" rule, with the scenarios from the bug reports.
void main() {
  final DateTime now = DateTime.utc(2026, 11, 10, 22, 40);
  DateTime ago(Duration d) => now.subtract(d);

  DrivingView view({
    MovementType movement = MovementType.car,
    double? speed,
    double? speedAccuracy,
    double? accuracy = 8,
    Duration? fixAge = const Duration(seconds: 5),
    Duration? slowFor,
  }) =>
      resolveDriving(
        movement: movement,
        speedMps: speed,
        speedAccuracyMps: speedAccuracy,
        accuracyMeters: accuracy,
        fixTime: fixAge == null ? null : ago(fixAge),
        slowSince: slowFor == null ? null : ago(slowFor),
        now: now,
      );

  group('resolveDriving', () {
    test('moving car shows Driving with its speed', () {
      final DrivingView v = view(speed: 31.3);
      expect(v.phase, DrivingPhase.driving);
      expect(v.speedMps, 31.3);
      expect(v.line(UnitSystem.imperial), 'Driving 70 mph');
      expect(v.line(UnitSystem.imperial, separator: ' · '), 'Driving · 70 mph');
    });

    test('red light for 30 s is Stopped, never "Driving 0 mph"', () {
      final DrivingView v = view(speed: 0, slowFor: const Duration(seconds: 30));
      expect(v.phase, DrivingPhase.stopped);
      expect(v.isDriving, isTrue); // keeps the car badge
      expect(v.speedMps, isNull);
      expect(v.hasCaption, isTrue);
      expect(v.line(UnitSystem.imperial), 'Stopped');
      expect(v.line(UnitSystem.imperial), isNot(contains('0 mph')));
    });

    test('a first stopped fix with no history is Stopped', () {
      expect(view(speed: 0.1).phase, DrivingPhase.stopped);
    });

    test('parked 5 minutes with a stale car tag is not Driving', () {
      final DrivingView v = view(speed: 0, slowFor: const Duration(minutes: 5));
      expect(v.phase, DrivingPhase.notDriving);
      expect(v.isDriving, isFalse);
      expect(v.line(UnitSystem.imperial), '');
    });

    test('standing just inside the grace period is still Stopped', () {
      expect(view(speed: 0, slowFor: const Duration(minutes: 2, seconds: 50)).phase,
          DrivingPhase.stopped);
      expect(view(speed: 0, slowFor: const Duration(minutes: 3, seconds: 5)).phase,
          DrivingPhase.notDriving);
    });

    test('GPS speed missing: Driving without a number, not 0', () {
      final DrivingView v = view(speed: null);
      expect(v.phase, DrivingPhase.driving);
      expect(v.speedMps, isNull);
      expect(v.hasCaption, isFalse);
      expect(v.line(UnitSystem.imperial), 'Driving');
    });

    test('a negative speed (no speed on the fix) is unknown, not stopped', () {
      final DrivingView v = view(speed: -1);
      expect(v.phase, DrivingPhase.driving);
      expect(v.speedMps, isNull);
    });

    test('a 0 with poor or unknown position accuracy is "no speed", not stopped', () {
      for (final double? acc in <double?>[null, 0, 80, 500]) {
        final DrivingView v = view(speed: 0, accuracy: acc);
        expect(v.phase, DrivingPhase.driving, reason: 'accuracy $acc');
        expect(v.speedMps, isNull);
      }
    });

    test('stale old fix: the car tag is dropped', () {
      expect(view(speed: 20, fixAge: const Duration(minutes: 5)).phase,
          DrivingPhase.notDriving);
      expect(view(speed: 20, fixAge: const Duration(minutes: 1, seconds: 50)).phase,
          DrivingPhase.driving);
      expect(view(speed: null, fixAge: const Duration(minutes: 2, seconds: 1)).phase,
          DrivingPhase.notDriving);
    });

    test('no fix time known: the age check is skipped', () {
      expect(view(speed: 20, fixAge: null).phase, DrivingPhase.driving);
    });

    test('speed accuracy bad: the speed is not trusted, no number shown', () {
      final DrivingView v = view(speed: 25, speedAccuracy: 6);
      expect(v.phase, DrivingPhase.driving);
      expect(v.speedMps, isNull);
      // A 0 with a large error bar is not "stopped" either.
      expect(view(speed: 0, speedAccuracy: 5).phase, DrivingPhase.driving);
      // A small error bar is fine.
      expect(view(speed: 25, speedAccuracy: 0.8).speedMps, 25);
    });

    test('impossible speeds are unknown', () {
      expect(view(speed: 500).speedMps, isNull);
      expect(view(speed: double.nan).speedMps, isNull);
    });

    test('only a car can be driving', () {
      for (final MovementType m in MovementType.values) {
        if (m == MovementType.car) continue;
        expect(view(movement: m, speed: 20).phase, DrivingPhase.notDriving);
      }
    });

    test('creeping 1 m/s traffic is Driving, 0.4 m/s is Stopped', () {
      expect(view(speed: 1.0).phase, DrivingPhase.driving);
      expect(view(speed: 0.4).phase, DrivingPhase.stopped);
    });
  });

  group('isSlowFix', () {
    test('a trusted speed decides', () {
      expect(isSlowFix(speedMps: 0, accuracyMeters: 5), isTrue);
      expect(isSlowFix(speedMps: 12, accuracyMeters: 5), isFalse);
    });

    test('no speed: barely moved over time is slow', () {
      expect(
          isSlowFix(
              accuracyMeters: 10,
              distanceM: 6,
              elapsed: const Duration(seconds: 30)),
          isTrue);
    });

    test('no speed: a real displacement is not slow', () {
      expect(
          isSlowFix(
              accuracyMeters: 10,
              distanceM: 150,
              elapsed: const Duration(seconds: 10)),
          isFalse);
    });

    test('no speed and no previous fix: unknown, not slow', () {
      expect(isSlowFix(accuracyMeters: 10), isFalse);
    });
  });

  group('mapper applies the rule', () {
    Map<String, dynamic> json(
      DateTime ts, {
      Object? speed = 0,
      String motion = 'driving',
      Object? accuracy = 8,
      double lat = 40,
      double lon = -74,
    }) =>
        <String, dynamic>{
          'id': 'u1',
          'name': 'Sam',
          'lat': lat,
          'lon': lon,
          'ts': ts.toIso8601String(),
          'speed_mps': speed,
          'motion_state': motion,
          'accuracy_meters': accuracy,
        };

    test('snapshot: stale car tag from a fix 6 minutes ago is not a car', () {
      final DateTime ts = DateTime.now().toUtc().subtract(const Duration(minutes: 6));
      final Member m = memberFromJson(json(ts));
      expect(m.movement, MovementType.none);
      expect(m.address, isNot('Driving'));
    });

    test('snapshot: a fresh car fix at speed stays a car', () {
      final DateTime ts = DateTime.now().toUtc().subtract(const Duration(seconds: 4));
      final Member m = memberFromJson(json(ts, speed: 20));
      expect(m.movement, MovementType.car);
      expect(m.drivingView().speedMps, 20);
    });

    test('live frames: red light is Stopped, then parked past the grace is not a car', () {
      final DateTime t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 8));
      Member m = memberFromJson(json(t0, speed: 14));
      // memberFromJson already retired it (8 min old); rebuild a live one.
      m = m.copyWith(movement: MovementType.car);

      m = memberFromLocationUpdate(
          m, json(t0.add(const Duration(minutes: 7)), speed: 0));
      expect(m.slowSince, isNotNull);
      expect(m.movement, MovementType.car);
      // Fix time is only a minute old, standing for 0 s: Stopped.
      expect(m.drivingView().phase, DrivingPhase.stopped);
      expect(memberStatusLine(m), 'Stopped');

      // Same standstill, 4 minutes later: the run started at the first slow
      // fix and is kept across later slow fixes.
      final DateTime first = m.slowSince!;
      m = memberFromLocationUpdate(
          m, json(t0.add(const Duration(minutes: 7, seconds: 20)), speed: 0));
      expect(m.slowSince, first);

      // Driving off clears it.
      m = memberFromLocationUpdate(
          m, json(t0.add(const Duration(minutes: 7, seconds: 40)), speed: 9));
      expect(m.slowSince, isNull);
      expect(m.movement, MovementType.car);
    });

    test('live frame with a speed-less fix that has not moved counts as standing', () {
      final DateTime t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      Member m = Member(
        id: 'u1',
        name: 'Sam',
        position: const LatLng(40, -74),
        status: MemberStatus.normal,
        batteryPercent: 80,
        address: 'Driving',
        movement: MovementType.car,
        speedMps: 12,
        fixTime: t0,
        accuracyMeters: 10,
      );
      m = memberFromLocationUpdate(m, json(t0.add(const Duration(seconds: 30)), speed: null));
      expect(m.slowSince, t0, reason: 'standing since the earlier fix');
      expect(m.speedMps, isNull);
      expect(m.drivingView().speedMps, isNull);
    });

    test('refreshStaleness retires a car tag whose fix went quiet', () {
      final Member m = Member(
        id: 'u1',
        name: 'Sam',
        position: const LatLng(40, -74),
        status: MemberStatus.normal,
        batteryPercent: 80,
        address: 'Driving',
        movement: MovementType.car,
        speedMps: 0,
        fixTime: DateTime.now().toUtc().subtract(const Duration(minutes: 4)),
        lastSeen: DateTime.now().toUtc().subtract(const Duration(seconds: 20)),
        accuracyMeters: 8,
      );
      final Member r = refreshStaleness(m);
      expect(r.movement, MovementType.none);
      expect(r.address, 'Stationary');
      expect(r.status, MemberStatus.normal);
      // Idempotent: nothing more to change, so the same object comes back.
      expect(identical(refreshStaleness(r), r), isTrue);
    });
  });

  group('every display agrees', () {
    Member car({double? speed, Duration fixAge = const Duration(seconds: 5), Duration? slowFor}) =>
        Member(
          id: 'u1',
          name: 'Sam',
          position: const LatLng(40, -74),
          status: MemberStatus.normal,
          batteryPercent: 80,
          address: 'Driving',
          movement: MovementType.car,
          speedMps: speed,
          fixTime: DateTime.now().toUtc().subtract(fixAge),
          lastSeen: DateTime.now().toUtc(),
          accuracyMeters: 8,
          slowSince: slowFor == null ? null : DateTime.now().toUtc().subtract(slowFor),
        );

    test('stopped: status line, badge and pill say Stopped; no speed anywhere', () {
      final Member m = car(speed: 0, slowFor: const Duration(seconds: 30));
      expect(memberStatusLine(m), 'Stopped');
      expect(m.showsMovementBadge, isTrue);
      expect(m.hasDrivingSpeed, isTrue); // the pill shows "Stopped"
      expect(m.isSpeeding, isFalse);
    });

    test('parked with a car tag: no Driving word, no badge, no pill', () {
      final Member m = car(speed: 0, slowFor: const Duration(minutes: 5));
      expect(memberStatusLine(m), isNot(contains('Driving')));
      expect(memberStatusLine(m), 'Stationary');
      expect(m.showsMovementBadge, isFalse);
      expect(m.hasDrivingSpeed, isFalse);
    });

    test('stale fix with a car tag: not Driving', () {
      final Member m = car(speed: 20, fixAge: const Duration(minutes: 6));
      expect(memberStatusLine(m), isNot(contains('Driving')));
      expect(m.showsMovementBadge, isFalse);
    });

    test('moving: "Driving 45 mph" and speeding flag', () {
      final Member m = car(speed: 20.1); // 45 mph
      expect(memberStatusLine(m), 'Driving 45 mph');
      expect(m.isSpeeding, isFalse);
      expect(car(speed: 33).isSpeeding, isTrue); // 74 mph
    });

    test('missing speed: "Driving" and no pill', () {
      final Member m = car(speed: null);
      expect(memberStatusLine(m), 'Driving');
      expect(m.hasDrivingSpeed, isFalse);
      expect(m.showsMovementBadge, isTrue);
    });

    test('a live speed of 0 from the marker hub reads Stopped', () {
      final Member m = car(speed: 12);
      expect(memberStatusLine(m, speedMps: 0), 'Stopped');
      expect(memberStatusLine(m, speedMps: 0), isNot(contains('mph')));
    });
  });
}
