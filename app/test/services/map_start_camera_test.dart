import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/map_start_camera.dart';
import 'package:shared_preferences/shared_preferences.dart';

final DateTime _now = DateTime.utc(2026, 11, 9, 12);

Member _m(String id, LatLng? p, {DateTime? at}) => Member(
      id: id,
      name: id,
      position: p,
      status: MemberStatus.normal,
      batteryPercent: 80,
      address: '',
      fixTime: at,
    );

void main() {
  const LatLng home = LatLng(52.37, 4.89);
  const LatLng far = LatLng(40.0, -74.0);

  group('StartCamera order: cached own -> fresh fix -> members', () {
    test('a remembered own position wins over the circle', () {
      final StartCamera s = StartCamera();
      expect(s.offerOwn(home, fresh: false), isTrue);
      expect(s.membersToFit(<Member>[_m('a', far, at: _now)], now: _now), isNull);
      expect(s.placedBy, StartSource.cachedOwn);
    });

    test('a fresh fix replaces a remembered one, never the other way round', () {
      final StartCamera s = StartCamera();
      expect(s.offerOwn(home, fresh: false), isTrue);
      expect(s.offerOwn(const LatLng(52.38, 4.9), fresh: true), isTrue);
      expect(s.offerOwn(far, fresh: false), isFalse);
      expect(s.offerOwn(far, fresh: true), isFalse, reason: 'one fresh centring only');
      expect(s.placedBy, StartSource.freshOwn);
    });

    test('without any own position the circle is framed, and own beats it later', () {
      final StartCamera s = StartCamera();
      expect(s.membersToFit(<Member>[_m('a', far, at: _now)], now: _now), <LatLng>[far]);
      expect(s.placedBy, StartSource.members);
      expect(s.membersToFit(<Member>[_m('a', home, at: _now)], now: _now), isNull,
          reason: 'framed once, never re-fitted on every roster');
      expect(s.offerOwn(home, fresh: false), isTrue);
    });

    test('nothing moves the camera after the user took it', () {
      final StartCamera s = StartCamera()..takeOver();
      expect(s.offerOwn(home, fresh: false), isFalse);
      expect(s.offerOwn(home, fresh: true), isFalse);
      expect(s.membersToFit(<Member>[_m('a', far, at: _now)], now: _now), isNull);
    });

    test('a pan after the start placement blocks the fresh fix too', () {
      final StartCamera s = StartCamera();
      expect(s.offerOwn(home, fresh: false), isTrue);
      s.takeOver();
      expect(s.offerOwn(far, fresh: true), isFalse);
    });
  });

  group('fit points never include stale or phantom positions', () {
    test('days-old, 0,0, out-of-range and missing points are skipped', () {
      final List<LatLng> pts = StartCamera.fitPoints(<Member>[
        _m('fresh', home, at: _now.subtract(const Duration(hours: 2))),
        _m('old', far, at: _now.subtract(const Duration(days: 3))),
        _m('null-island', const LatLng(0, 0), at: _now),
        _m('none', null),
        _m('no-time', const LatLng(51.5, -0.1)),
      ], now: _now);
      expect(pts, <LatLng>[home, const LatLng(51.5, -0.1)]);
    });

    test('only stale members: the camera stays where it is', () {
      final StartCamera s = StartCamera();
      expect(
          s.membersToFit(<Member>[_m('old', far, at: _now.subtract(const Duration(days: 9)))], now: _now),
          isNull);
      expect(s.placedBy, StartSource.none);
    });
  });

  group('OwnPositionCache', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      OwnPositionCache.debugReset();
    });

    test('survives a cold start (written, then loaded by a fresh process)', () async {
      await OwnPositionCache.save(home, now: _now);
      OwnPositionCache.debugReset();
      expect(OwnPositionCache.value, isNull);
      await OwnPositionCache.load();
      expect(OwnPositionCache.value!.latitude, closeTo(home.latitude, 1e-9));
      expect(OwnPositionCache.value!.longitude, closeTo(home.longitude, 1e-9));
    });

    test('rejects phantom points and is cleared on sign-out', () async {
      await OwnPositionCache.save(const LatLng(0, 0), now: _now);
      expect(OwnPositionCache.value, isNull);
      await OwnPositionCache.save(home, now: _now);
      await OwnPositionCache.clear();
      OwnPositionCache.debugReset();
      await OwnPositionCache.load();
      expect(OwnPositionCache.value, isNull);
    });

    test('an older report never replaces a newer fix', () async {
      await OwnPositionCache.save(home, now: _now);
      await OwnPositionCache.save(far, at: _now.subtract(const Duration(hours: 3)));
      expect(OwnPositionCache.value, home);
    });

    test('a small move within minutes is not rewritten; a real move is', () async {
      await OwnPositionCache.save(home, now: _now);
      await OwnPositionCache.save(const LatLng(52.3701, 4.8901), now: _now.add(const Duration(minutes: 1)));
      expect(OwnPositionCache.value, home);
      await OwnPositionCache.save(far, now: _now.add(const Duration(minutes: 2)));
      expect(OwnPositionCache.value, far);
    });
  });
}
