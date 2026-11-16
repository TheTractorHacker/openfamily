import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/utils/member_clustering.dart';

void main() {
  test('fan-out ring grows so neighbours never touch', () {
    for (int n = 2; n <= 24; n++) {
      final double r = fanOutRadiusFor(n);
      expect(r, greaterThanOrEqualTo(kFanOutRadiusPx));
      final double gap = 2 * r * math.sin(math.pi / n);
      expect(gap, greaterThanOrEqualTo(kFanOutMinGapPx - 1e-9), reason: 'n=$n');
    }
  });

  test('cluster radius covers a full avatar box', () {
    expect(kClusterRadiusPx, greaterThanOrEqualTo(58));
    expect(const Offset(0, 0).distance, 0);
  });
}
