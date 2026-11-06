import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/private_places.dart';

// The same cases as the server's geofence tests (backend/internal/handlers
// geofence_drift_test.go, geofence_eval.go rules), driven by a fake clock.

void main() {
  late DateTime now;
  late PlaceEvaluator ev;
  const SealedPlace home = SealedPlace(id: 'home', name: 'Home', lat: 40, lon: -75, radiusMeters: 100);
  // ~0.003 deg of latitude is ~333 m: well outside a 100 m place.
  const double farLat = 40.003;

  setUp(() {
    now = DateTime.utc(2026, 11, 6, 12);
    ev = PlaceEvaluator(now: () => now);
  });

  List<PlaceEvent> fix(double lat, {double? acc = 8, Duration at = Duration.zero, List<SealedPlace> places = const <SealedPlace>[home]}) =>
      ev.onFix(lat, -75, now.add(at), acc, places);

  test('first fix is a silent baseline, inside or outside', () {
    expect(fix(40), isEmpty); // already home: no "arrived"
    final PlaceEvaluator other = PlaceEvaluator(now: () => now);
    expect(other.onFix(farLat, -75, now, 8, <SealedPlace>[home]), isEmpty);
  });

  test('arrival after being outside fires once, departure fires once', () {
    fix(farLat);
    now = now.add(const Duration(minutes: 5));
    final List<PlaceEvent> arrived = fix(40);
    expect(arrived.length, 1);
    expect(arrived.single.entered, isTrue);
    expect(arrived.single.placeName, 'Home');
    expect(fix(40), isEmpty); // still inside, nothing new
    now = now.add(const Duration(minutes: 5));
    final List<PlaceEvent> left = fix(farLat);
    expect(left.single.entered, isFalse);
  });

  test('GPS drift with poor accuracy never raises a false departure (server drift test)', () {
    fix(40); // accurate baseline at the centre
    for (final (int i, double a) in <(int, double)>[(1, 300), (2, 450), (3, 800), (4, 250)]) {
      expect(fix(farLat, acc: a, at: Duration(seconds: i)), isEmpty, reason: 'accuracy $a m must not drive a transition');
    }
    now = now.add(const Duration(minutes: 1));
    final List<PlaceEvent> real = fix(farLat, acc: 10);
    expect(real.length, 1, reason: 'an accurate departure fires exactly one exit');
    expect(real.single.entered, isFalse);
  });

  test('accuracy gate: exactly 100 m is usable, above is not, unknown is trusted', () {
    expect(ev.fixUsable(100), isTrue);
    expect(ev.fixUsable(100.1), isFalse);
    expect(ev.fixUsable(null), isTrue);
  });

  test('debounce: a transition inside the window stays pending and fires after it', () {
    fix(farLat); // baseline outside
    now = now.add(const Duration(minutes: 5));
    expect(fix(40).length, 1); // arrived, notified at t0
    now = now.add(const Duration(seconds: 20));
    expect(fix(farLat), isEmpty); // left only 20 s later: debounced, pending
    expect(ev.tick(<SealedPlace>[home]), isEmpty); // still inside the window
    now = now.add(const Duration(seconds: 50));
    final List<PlaceEvent> late = ev.tick(<SealedPlace>[home]);
    expect(late.length, 1);
    expect(late.single.entered, isFalse);
    expect(ev.tick(<SealedPlace>[home]), isEmpty); // idempotent: fired once
  });

  test('rapid reversal inside the window is dropped (no stale alert)', () {
    fix(farLat);
    now = now.add(const Duration(minutes: 5));
    expect(fix(40).length, 1); // arrived
    now = now.add(const Duration(seconds: 10));
    expect(fix(farLat), isEmpty); // exit pending
    now = now.add(const Duration(seconds: 10));
    expect(fix(40), isEmpty); // back inside before the window: superseded
    now = now.add(const Duration(minutes: 5));
    expect(ev.tick(<SealedPlace>[home]), isEmpty);
  });

  test('pending exit then a later re-entry after the window fires the old exit first', () {
    fix(farLat);
    now = now.add(const Duration(minutes: 5));
    fix(40); // arrived
    now = now.add(const Duration(seconds: 20));
    fix(farLat); // exit pending
    now = now.add(const Duration(seconds: 61));
    final List<PlaceEvent> e = fix(40); // back after the window: the circle must hear about the exit
    expect(e.length, 1);
    expect(e.single.entered, isFalse);
  });

  test('a stale (older) fix is ignored and cannot flip state', () {
    fix(farLat, at: const Duration(minutes: 10));
    now = now.add(const Duration(minutes: 20));
    expect(ev.onFix(40, -75, now.subtract(const Duration(minutes: 30)), 8, <SealedPlace>[home]), isEmpty);
    expect(ev.isInside('home'), isFalse);
  });

  test('a non-notifiable direction syncs silently', () {
    const SealedPlace noExit = SealedPlace(id: 'w', name: 'Work', lat: 40, lon: -75, radiusMeters: 100, exitNotify: false);
    ev.onFix(40, -75, now, 8, <SealedPlace>[noExit]);
    now = now.add(const Duration(minutes: 5));
    expect(ev.onFix(farLat, -75, now, 8, <SealedPlace>[noExit]), isEmpty);
    now = now.add(const Duration(minutes: 5));
    final List<PlaceEvent> back = ev.onFix(40, -75, now, 8, <SealedPlace>[noExit]);
    expect(back.single.entered, isTrue); // arrival after a silent exit still notifies
  });

  test('editing a place restarts its state; deleting removes it', () {
    fix(farLat);
    ev.resetPlace('home');
    expect(fix(40), isEmpty); // silent baseline again
    const SealedPlace gone = SealedPlace(id: 'home', name: 'Home', lat: 40, lon: -75, radiusMeters: 100, deleted: true);
    now = now.add(const Duration(minutes: 5));
    expect(ev.onFix(farLat, -75, now, 8, <SealedPlace>[gone]), isEmpty);
    expect(ev.isInside('home'), isNull);
  });

  test('state survives a restart (serialise / restore)', () {
    fix(farLat);
    now = now.add(const Duration(minutes: 5));
    fix(40);
    final PlaceEvaluator re = PlaceEvaluator(now: () => now)..restore(ev.toJson());
    expect(re.isInside('home'), isTrue);
    now = now.add(const Duration(minutes: 5));
    expect(re.onFix(farLat, -75, now, 8, <SealedPlace>[home]).single.entered, isFalse);
  });

  group('place records', () {
    test('sealed place JSON round trips and rejects garbage', () {
      const SealedPlace p = SealedPlace(id: 'a', name: 'School', lat: 1.5, lon: 2.5, radiusMeters: 150, type: 'school', address: 'x');
      final SealedPlace? r = SealedPlace.fromJson(p.toJson());
      expect(r?.name, 'School');
      expect(r?.radiusMeters, 150);
      expect(SealedPlace.fromJson(<String, dynamic>{'id': 'a', 'name': 'x', 'lat': 91, 'lon': 0, 'r': 10}), isNull);
      expect(SealedPlace.fromJson(<String, dynamic>{'id': 'a', 'name': 'x', 'lat': 1, 'lon': 0, 'r': -1}), isNull);
      expect(SealedPlace.fromJson(<String, dynamic>{'name': 'x'}), isNull);
    });

    test('the place book keeps the newest version and honours tombstones', () {
      final PlaceBook b = PlaceBook();
      const SealedPlace v1 = SealedPlace(id: 'a', name: 'One', lat: 1, lon: 1, radiusMeters: 100);
      const SealedPlace v2 = SealedPlace(id: 'a', name: 'Two', lat: 1, lon: 1, radiusMeters: 100);
      expect(b.apply(v2, 200), isTrue);
      expect(b.apply(v1, 100), isFalse); // older does not win
      expect(b.places.single.name, 'Two');
      expect(b.apply(const SealedPlace(id: 'a', name: 'Two', lat: 1, lon: 1, radiusMeters: 100, deleted: true), 300), isTrue);
      expect(b.places, isEmpty);
      expect(b.byId('a'), isNull);
    });
  });
}
