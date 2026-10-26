import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/member_motion_hub.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/watch_client.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('watch never throws and reports failure', () async {
    final WatchClient ok =
        WatchClient(post: (String p, {Object? body}) async => <String, dynamic>{});
    expect(await ok.watch('u1', circleId: 'c1'), isTrue);
    final WatchClient failing =
        WatchClient(post: (String p, {Object? body}) async => throw Exception('x'));
    expect(await failing.watch('u1'), isFalse);
  });

  test('watch body shape', () async {
    Object? sent;
    final WatchClient c = WatchClient(post: (String p, {Object? body}) async {
      sent = body;
    });
    await c.watch('u1', circleId: 'c1');
    expect(sent, <String, Object?>{'user_id': 'u1', 'circle_id': 'c1'});
    await c.watch('u1', circleId: 'all');
    expect(sent, <String, Object?>{'user_id': 'u1'});
  });

  test('hub speed is the freshest smoothed GPS speed, 0 when stale', () {
    DateTime now = DateTime.utc(2026, 1, 1, 12);
    final MemberMotionHub hub = MemberMotionHub(clock: () => now);
    Member at(int sec, double mps) => Member(
          id: 'a',
          name: 'A',
          position: LatLng(40, -100 + sec * 0.0002),
          status: MemberStatus.normal,
          batteryPercent: 50,
          address: 'Driving',
          movement: MovementType.car,
          speedMps: mps,
          fixTime: DateTime.utc(2026, 1, 1, 12).add(Duration(seconds: sec)),
        );
    hub.update(<Member>[at(0, 13.4)]);
    now = now.add(const Duration(seconds: 1));
    final Member m = at(1, 13.4);
    hub.update(<Member>[m]);
    expect(UnitSystem.imperial.formatSpeed(hub.liveSpeedMps(m)!), '30 mph');
    expect(UnitSystem.metric.formatSpeed(hub.liveSpeedMps(m)!), '48 km/h');
    now = now.add(const Duration(seconds: 20));
    expect(hub.liveSpeedMps(m), 0);
    hub.reset();
  });
}
