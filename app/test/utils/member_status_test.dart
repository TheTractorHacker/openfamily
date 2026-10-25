import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/utils/member_status.dart';

import '../support/location_fixtures.dart';

void main() {
  test('status lines', () {
    expect(memberStatusLine(kDriver), 'Driving 42 mph');
    expect(memberStatusLine(kAtHome), 'At Home');
    expect(
      memberStatusLine(kSelf, sharingPaused: true),
      'Location sharing paused',
    );
    expect(memberStatusLine(kOffline), 'No location yet');
    expect(memberStatusLine(kSelf), 'Market St');
  });

  test('battery alert only when low', () {
    expect(memberBatteryAlert(kAtHome), 'Battery 18%');
    expect(memberBatteryAlert(kDriver), isNull);
    expect(memberBatteryAlert(kOffline), isNull);
  });

  test('clock formatting', () {
    expect(formatClock(DateTime(2026, 1, 1, 15, 10)), '3:10 pm');
    expect(formatClock(DateTime(2026, 1, 1, 0, 5)), '12:05 am');
    expect(formatClock(DateTime(2026, 1, 1, 12, 0)), '12:00 pm');
  });
}
