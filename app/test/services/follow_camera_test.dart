import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/follow_camera.dart';
import 'package:openfamily/services/marker_motion.dart';

MotionSample at(double lat, double lon) => MotionSample(
      position: LatLng(lat, lon),
      headingDeg: 0,
      speedMps: 10,
      animating: true,
    );

class _Cam {
  LatLng center = const LatLng(10, 10);
  double zoom = 12;
  int moves = 0;
  late final FollowCamera follow = FollowCamera(
    moveTo: (LatLng c, double z) {
      center = c;
      zoom = z;
      moves++;
    },
    camera: () => (center: center, zoom: zoom),
  );
}

void main() {
  test('glides onto the member then tracks them every frame', () {
    final _Cam c = _Cam();
    c.follow.start('a');
    Duration t = Duration.zero;
    bool intro = true;
    int frames = 0;
    while (intro && frames < 200) {
      intro = c.follow.update(t, at(20, 20));
      t += const Duration(milliseconds: 16);
      frames++;
    }
    expect(frames, lessThan(40), reason: 'intro is a short glide');
    expect(c.center.latitude, closeTo(20, 1e-9));
    expect(c.zoom, 16, reason: 'zoomed out below 14 -> 16');
    // Then it simply follows the moving display position.
    for (int i = 1; i <= 10; i++) {
      c.follow.update(t, at(20 + i * 0.001, 20));
      t += const Duration(milliseconds: 16);
      expect(c.center.latitude, closeTo(20 + i * 0.001, 1e-9));
    }
    expect(c.zoom, 16);
  });

  test('keeps the user zoom when already zoomed in', () {
    final _Cam c = _Cam()..zoom = 17.5;
    c.follow.start('a');
    Duration t = Duration.zero;
    for (int i = 0; i < 60; i++) {
      c.follow.update(t, at(11, 11));
      t += const Duration(milliseconds: 16);
    }
    expect(c.zoom, 17.5);
  });

  test('does not move the camera when the target has not moved', () {
    final _Cam c = _Cam()..zoom = 16;
    c.follow.start('a');
    Duration t = Duration.zero;
    for (int i = 0; i < 40; i++) {
      c.follow.update(t, at(11, 11));
      t += const Duration(milliseconds: 16);
    }
    final int before = c.moves;
    for (int i = 0; i < 30; i++) {
      c.follow.update(t, at(11, 11));
      t += const Duration(milliseconds: 16);
    }
    expect(c.moves, before);
  });

  test('a user gesture breaks the lock; recenter restores it', () {
    final _Cam c = _Cam()..zoom = 16;
    c.follow.start('a');
    Duration t = Duration.zero;
    c.follow.update(t, at(11, 11));
    c.follow.breakLock();
    expect(c.follow.locked, isFalse);
    expect(c.follow.targetId, 'a', reason: 'target kept for the pill');
    final int moves = c.moves;
    c.follow.update(t += const Duration(seconds: 1), at(12, 12));
    expect(c.moves, moves, reason: 'camera is the user\'s again');
    c.follow.start('a');
    for (int i = 0; i < 40; i++) {
      c.follow.update(t += const Duration(milliseconds: 16), at(12, 12));
    }
    expect(c.center.latitude, closeTo(12, 1e-9));
  });

  test('keeps following when the member is far off screen', () {
    final _Cam c = _Cam()..zoom = 16;
    c.follow.start('a');
    Duration t = Duration.zero;
    for (int i = 0; i < 40; i++) {
      c.follow.update(t += const Duration(milliseconds: 16), at(11, 11));
    }
    c.follow.update(t += const Duration(milliseconds: 16), at(45, 100));
    expect(c.center, const LatLng(45, 100));
  });

  test('stop forgets the target and never moves again', () {
    final _Cam c = _Cam();
    c.follow.start('a');
    c.follow.stop();
    expect(c.follow.targetId, isNull);
    expect(c.follow.update(Duration.zero, at(1, 1)), isFalse);
    expect(c.moves, 0);
  });
}
