import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/sharing_service.dart';

void main() {
  test('pauseUntilTomorrow is 07:00 local on the next calendar day', () {
    final DateTime t = pauseUntilTomorrow(DateTime(2026, 12, 31, 23, 30));
    expect(t, DateTime(2027, 1, 1, 7));
    expect(pauseUntilTomorrow(DateTime(2026, 3, 5, 0, 5)), DateTime(2026, 3, 6, 7));
  });

  test('formatTimeLeft', () {
    expect(formatTimeLeft(Duration.zero), 'ended');
    expect(formatTimeLeft(const Duration(seconds: 20)), 'less than a minute left');
    expect(formatTimeLeft(const Duration(minutes: 45)), '45 min left');
    expect(formatTimeLeft(const Duration(hours: 2)), '2 h left');
    expect(formatTimeLeft(const Duration(hours: 2, minutes: 5)), '2 h 5 min left');
    expect(formatTimeLeft(const Duration(hours: 26)), '1 d 2 h left');
  });

  test('SharingPause parses and expires client-side', () {
    final SharingPause p = SharingPause.fromJson(<String, dynamic>{
      'paused': true,
      'paused_until': '2030-01-01T10:00:00Z',
    });
    expect(p.paused, isTrue);
    expect(p.activeAt(DateTime.utc(2030, 1, 1, 9)), isTrue);
    expect(p.activeAt(DateTime.utc(2030, 1, 1, 11)), isFalse);
    expect(SharingPause.fromJson(<String, dynamic>{}).paused, isFalse);
  });

  test('LiveShares parses both directions and drops expired ones', () {
    final LiveShares s = LiveShares.fromJson(<String, dynamic>{
      'outgoing': <Object>[
        <String, dynamic>{
          'id': 'a', 'user_id': 'u1', 'name': 'Sam',
          'expires_at': '2030-01-01T10:00:00Z',
        },
      ],
      'incoming': <Object>[
        <String, dynamic>{
          'id': 'b', 'user_id': 'u2', 'name': 'Ella', 'paused': true,
          'expires_at': '2020-01-01T10:00:00Z',
        },
        <String, dynamic>{
          'id': 'c', 'user_id': 'u3', 'name': 'Max', 'lat': 1.5, 'lon': 2.5,
          'expires_at': '2030-01-01T10:00:00Z',
        },
      ],
    });
    expect(s.outgoing.single.name, 'Sam');
    expect(s.incoming.first.paused, isTrue);
    expect(s.incoming.last.lat, 1.5);
    final LiveShares live = s.withoutExpired(DateTime.utc(2025));
    expect(live.incoming.map((LiveShare e) => e.id), <String>['c']);
  });
}
