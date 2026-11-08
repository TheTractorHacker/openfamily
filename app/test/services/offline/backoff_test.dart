import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/offline/backoff.dart';

void main() {
  test('delays grow exponentially, stay inside the jitter band and are capped', () {
    final Backoff b = Backoff(base: const Duration(seconds: 2), max: const Duration(seconds: 60), random: Random(7));
    final List<int> ms = <int>[for (int i = 0; i < 12; i++) b.next().inMilliseconds];
    for (int i = 0; i < ms.length; i++) {
      final int ceiling = min(60000, 2000 * (1 << i));
      expect(ms[i], inInclusiveRange((ceiling * 0.5).round(), ceiling), reason: 'attempt $i');
    }
    expect(ms.last, lessThanOrEqualTo(60000));
    expect(ms.last, greaterThanOrEqualTo(30000));
  });

  test('reset starts over, and a huge attempt count cannot overflow', () {
    final Backoff b = Backoff(base: const Duration(seconds: 1), max: const Duration(minutes: 5), random: Random(1));
    for (int i = 0; i < 200; i++) {
      expect(b.next(), lessThanOrEqualTo(const Duration(minutes: 5)));
    }
    b.reset();
    expect(b.attempt, 0);
    expect(b.next(), lessThanOrEqualTo(const Duration(seconds: 1)));
  });

  test('two phones do not retry on the same second (jitter)', () {
    final Set<int> firsts = <int>{
      for (int seed = 0; seed < 20; seed++) Backoff(random: Random(seed)).next().inMilliseconds,
    };
    expect(firsts.length, greaterThan(10));
  });
}
