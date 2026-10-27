import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
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

  group('placePresenceLabel', () {
    final DateTime now = DateTime(2026, 6, 10, 16, 0);
    PlacePresence at(DateTime t) => PlacePresence(
        placeId: 'p', placeName: 'Home', isAt: true, since: t);

    test('arrived today shows the clock time', () {
      expect(placePresenceLabel(at(DateTime(2026, 6, 10, 15, 42)), now: now),
          'At Home since 3:42 PM');
    });

    test('arrived earlier shows the day', () {
      expect(placePresenceLabel(at(DateTime(2026, 6, 9, 18, 10)), now: now),
          'At Home since yesterday 6:10 PM');
      expect(placePresenceLabel(at(DateTime(2026, 6, 3, 18, 10)), now: now),
          'At Home since Jun 3');
    });

    test('departures are relative', () {
      PlacePresence left(Duration ago) => PlacePresence(
          placeId: 'p',
          placeName: 'Work',
          isAt: false,
          since: now.subtract(ago));
      expect(placePresenceLabel(left(const Duration(seconds: 20)), now: now),
          'Left Work just now');
      expect(placePresenceLabel(left(const Duration(minutes: 25)), now: now),
          'Left Work 25 min ago');
      expect(placePresenceLabel(left(const Duration(hours: 3)), now: now),
          'Left Work 3 hr ago');
      expect(placePresenceLabel(left(const Duration(days: 2)), now: now),
          'Left Work 2 d ago');
    });

    test('status line uses presence for a parked member only', () {
      final Member parked = kSelf.copyWith(
          placePresence: PlacePresence(
              placeId: 'p',
              placeName: 'Work',
              isAt: false,
              since: DateTime.now().subtract(const Duration(minutes: 25))));
      expect(memberStatusLine(parked), 'Left Work 25 min ago');
    });
  });
}
