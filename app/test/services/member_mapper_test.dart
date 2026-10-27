import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/services/member_mapper.dart';

void main() {
  liveMapSpeedTests();
  group('place presence', () {
    test('parses place_presence from a members payload', () {
      final m = memberFromJson(<String, dynamic>{
        'id': 'm',
        'name': 'Sam',
        'place_presence': <String, dynamic>{
          'place_id': 'p1',
          'place_name': 'Home',
          'state': 'at',
          'since': '2026-06-10T15:42:00Z',
        },
      });
      expect(m.placePresence?.placeName, 'Home');
      expect(m.placePresence?.isAt, isTrue);
      expect(m.placePresence?.since, DateTime.utc(2026, 6, 10, 15, 42));
    });

    test('absent or malformed place_presence is null', () {
      expect(memberFromJson(<String, dynamic>{'id': 'm'}).placePresence,
          isNull);
      expect(
          memberFromJson(<String, dynamic>{
            'id': 'm',
            'place_presence': <String, dynamic>{'state': 'bogus'},
          }).placePresence,
          isNull);
    });

    test('a live location frame keeps the snapshot place presence', () {
      final m = memberFromJson(<String, dynamic>{
        'id': 'm',
        'place_presence': <String, dynamic>{
          'place_id': 'p1',
          'place_name': 'Work',
          'state': 'left',
          'since': '2026-06-10T15:42:00Z',
        },
      });
      final next = memberFromLocationUpdate(m, <String, dynamic>{
        'lat': 1.0,
        'lon': 2.0,
        'ts': '2026-06-10T16:00:00Z',
      });
      expect(next.placePresence?.placeName, 'Work');
      expect(next.placePresence?.isAt, isFalse);
    });
  });
  group('member avatar metadata', () {
    test('keeps a newer avatar when a stale WebSocket frame arrives', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'has_avatar': true,
        'avatar_updated_at': '2026-08-22T12:00:00Z',
        'avatar_version': 7,
      });

      expect(member.hasAvatar, isTrue);
      expect(member.avatarVersion, 7);

      final stale = memberFromAvatarUpdate(member, <String, dynamic>{
        'has_avatar': false,
        'avatar_version': 6,
      });

      expect(identical(stale, member), isTrue);
      expect(stale.hasAvatar, isTrue);

      final removal = memberFromAvatarUpdate(member, <String, dynamic>{
        'has_avatar': false,
        'avatar_version': 8,
      });

      expect(removal.hasAvatar, isFalse);
      expect(removal.avatarVersion, 8);
      expect(removal.avatarUpdatedAt, isNull);
    });

    test('does not apply an unversioned avatar frame', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'has_avatar': true,
        'avatar_version': 1,
      });

      final unchanged = memberFromAvatarUpdate(member, <String, dynamic>{
        'has_avatar': false,
      });

      expect(identical(unchanged, member), isTrue);
    });
  });

  group('last seen / presence', () {
    final freshTs = DateTime.now().toUtc().subtract(const Duration(minutes: 1));

    test('uses last_seen_at when it is newer than the location ts', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        // Location is 30 minutes old — would be stale on its own.
        'ts': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 30))
            .toIso8601String(),
        // Device heartbeat is fresh.
        'last_seen_at': freshTs.toIso8601String(),
      });

      expect(member.lastSeen, freshTs);
      expect(member.status, MemberStatus.normal);
    });

    test('keeps the location ts when it is the newer of the two', () {
      final ts = DateTime.now().toUtc();
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': ts.toIso8601String(),
        'last_seen_at':
            ts.subtract(const Duration(minutes: 5)).toIso8601String(),
      });

      expect(member.lastSeen, ts);
    });

    test('an older location frame cannot regress a newer heartbeat', () {
      final heartbeatTs = DateTime.now().toUtc();
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': heartbeatTs.toIso8601String(),
      });

      final updated = memberFromLocationUpdate(member, <String, dynamic>{
        'user_id': 'member-1',
        'lat': 37.1,
        'lon': -122.1,
        'ts': heartbeatTs.subtract(const Duration(hours: 1)).toIso8601String(),
        'last_seen_at':
            heartbeatTs.subtract(const Duration(seconds: 2)).toIso8601String(),
      });

      expect(updated.position, const LatLng(37.1, -122.1));
      expect(updated.lastSeen, heartbeatTs);
    });

    test('a stale stationary member goes back to normal on a presence frame',
        () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 30))
            .toIso8601String(),
      });
      expect(member.status, MemberStatus.stopped);

      final refreshed = memberFromPresenceUpdate(member, <String, dynamic>{
        'user_id': 'member-1',
        'ts': freshTs.toIso8601String(),
        'battery_pct': 88,
      });

      expect(refreshed.status, MemberStatus.normal);
      expect(refreshed.lastSeen, freshTs);
      // Liveness only: pin and battery update, nothing else moves.
      expect(refreshed.position, member.position);
      expect(refreshed.batteryPercent, 88);
      expect(refreshed.speedMph, member.speedMph);
    });

    test('ignores equal-or-older presence frames and malformed frames', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': freshTs.toIso8601String(),
      });

      final older = memberFromPresenceUpdate(member, <String, dynamic>{
        'user_id': 'member-1',
        'ts': freshTs.subtract(const Duration(seconds: 1)).toIso8601String(),
      });
      final malformed = memberFromPresenceUpdate(member, <String, dynamic>{
        'user_id': 'member-1',
        'ts': 'not-a-timestamp',
      });
      final noUser = memberFromPresenceUpdate(member, <String, dynamic>{
        'ts': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      });

      expect(identical(older, member), isTrue);
      expect(identical(malformed, member), isTrue);
      expect(identical(noUser, member), isTrue);
    });
  });

  group('address labels', () {
    test('a fresh still member is Stationary, not Moving', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': DateTime.now().toUtc().toIso8601String(),
      });

      expect(member.address, 'Stationary');
      expect(member.status.label, 'Live');
    });

    test('driving keeps Driving even when a place would match', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': DateTime.now().toUtc().toIso8601String(),
        'motion_state': 'driving',
      });
      expect(member.address, 'Driving');
    });

    test('a still member inside a saved place is labeled with the place name',
        () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.7749,
        'lon': -122.4194,
        'ts': DateTime.now().toUtc().toIso8601String(),
      });
      final Place home = Place(
        id: 'home-1',
        name: 'Home',
        icon: Place.iconForType('home'),
        address: '',
        position: LatLng(37.7749, -122.4194),
        radiusMeters: 150,
        type: 'home',
      );

      expect(member.address, 'Stationary');
      expect(applyPlaceAddress(member, <Place>[home]).address, 'Home');
    });

    test('a still member outside every place stays Stationary', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.78,
        'lon': -122.41,
        'ts': DateTime.now().toUtc().toIso8601String(),
      });
      final Place home = Place(
        id: 'home-1',
        name: 'Home',
        icon: Place.iconForType('home'),
        address: '',
        position: LatLng(37.7749, -122.4194),
        radiusMeters: 80,
        type: 'home',
      );

      expect(applyPlaceAddress(member, <Place>[home]).address, 'Stationary');
    });

    test('a stale member is labeled with the pin age, not the last-seen label',
        () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 8))
            .toIso8601String(),
      });

      expect(member.status, MemberStatus.stopped);
      // The address describes the pin so it never duplicates the liveness
      // "Last seen" field shown beside it.
      expect(member.address, startsWith('Position from '));
      expect(member.address, isNot(startsWith('Last seen')));
    });

    test('a stale member inside a saved place keeps the pin-age label', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.7749,
        'lon': -122.4194,
        'ts': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 8))
            .toIso8601String(),
      });
      final Place home = Place(
        id: 'home-1',
        name: 'Home',
        icon: Place.iconForType('home'),
        address: '',
        position: const LatLng(37.7749, -122.4194),
        radiusMeters: 150,
        type: 'home',
      );

      expect(isStaleAddress(member.address), isTrue);
      expect(applyPlaceAddress(member, <Place>[home]).address,
          member.address);
    });

    test('refreshStaleness uses the pin-age wording', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'name': 'Sam Rivera',
        'lat': 37.0,
        'lon': -122.0,
        'ts': DateTime.now().toUtc().toIso8601String(),
      });
      expect(member.address, 'Stationary');

      // Simulate the staleness timer firing long after the last report.
      final DateTime eightHoursAgo =
          DateTime.now().toUtc().subtract(const Duration(hours: 8));
      final Member aged = member.copyWith(lastSeen: eightHoursAgo);
      final Member refreshed = refreshStaleness(aged);

      expect(refreshed.status, MemberStatus.stopped);
      expect(refreshed.address, 'Position from 8h ago');
      expect(isStaleAddress(refreshed.address), isTrue);
    });
  });

  group('movement inference from speed (motion_state absent, iOS)', () {
    test('infers driving when speed is unambiguously vehicle speed', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'speed_mps': 12, // ~27 mph.
      });

      expect(member.movement, MovementType.car);
      expect(member.speedMph, isNotNull);
    });

    test('does not infer movement below the confident threshold', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'speed_mps': 2.4, // ~5 mph — could be GPS drift or a jog.
      });

      expect(member.movement, MovementType.none);
    });

    test('keeps the frame silent when speed is omitted', () {
      final member = memberFromJson(<String, dynamic>{'id': 'member-1'});

      expect(member.movement, MovementType.none);
      expect(member.speedMph, isNull);
    });

    test('motion_state wins over speed inference when both are present', () {
      final member = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'motion_state': 'cycling',
        'speed_mps': 12,
      });

      expect(member.movement, MovementType.bike);
    });

    test(
        'WebSocket frames upgrade to driving from speed but keep a known '
        'badge when speed is low', () {
      final Member driving = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'motion_state': 'driving',
        'speed_mps': 20,
      });

      // Red-light speed dip: no downgrade to "none".
      final Member atLight =
          memberFromLocationUpdate(driving, <String, dynamic>{
        'lat': 37.0,
        'lon': -122.0,
        'speed_mps': 0.4,
      });
      expect(atLight.movement, MovementType.car);

      // A fast iOS fix (no motion_state on iOS) is classified as driving.
      final Member fromSpeed = memberFromLocationUpdate(
        memberFromJson(<String, dynamic>{'id': 'member-1'}),
        <String, dynamic>{'lat': 37.0, 'lon': -122.0, 'speed_mps': 31},
      );
      expect(fromSpeed.movement, MovementType.car);
    });

    test('refreshStaleness clears a stale movement badge', () {
      final Member driving = memberFromJson(<String, dynamic>{
        'id': 'member-1',
        'lat': 37.0,
        'lon': -122.0,
        'motion_state': 'driving',
        'speed_mps': 20,
        'ts': DateTime.now().toUtc().toIso8601String(),
      });
      expect(driving.movement, MovementType.car);

      // The device parks and stops reporting; the staleness timer fires.
      final DateTime eightHoursAgo =
          DateTime.now().toUtc().subtract(const Duration(hours: 8));
      final Member refreshed =
          refreshStaleness(driving.copyWith(lastSeen: eightHoursAgo));

      expect(refreshed.status, MemberStatus.stopped);
      expect(refreshed.movement, MovementType.none);

      // Re-run: the cleared state is stable (no spurious onMembersChanged).
      final Member again = refreshStaleness(refreshed);
      expect(identical(again, refreshed), isTrue);
    });
  });
}

void liveMapSpeedTests() {
  group('live speed and heading', () {
    test('keeps the unrounded GPS speed; speedMph is derived', () {
      final Member m = memberFromJson(<String, dynamic>{
        'id': 'a',
        'speed_mps': 13.4,
        'heading_deg': 271.5,
        'ts': '2026-01-01T12:00:00Z',
      });
      expect(m.speedMps, 13.4);
      expect(m.speedMph, 30);
      expect(m.headingDeg, 271.5);
      expect(m.fixTime, DateTime.utc(2026, 1, 1, 12));
    });

    test('speed 0 is a real 0, absent speed is unknown', () {
      expect(memberFromJson(<String, dynamic>{'id': 'a', 'speed_mps': 0}).speedMps, 0);
      expect(memberFromJson(<String, dynamic>{'id': 'a'}).speedMps, isNull);
      expect(memberFromJson(<String, dynamic>{'id': 'a'}).headingDeg, isNull);
    });

    test('a location frame replaces the speed and clears it when omitted', () {
      final Member base = memberFromJson(<String, dynamic>{
        'id': 'a',
        'lat': 1.0,
        'lon': 2.0,
        'speed_mps': 20.0,
        'motion_state': 'driving',
      });
      final Member fresh = memberFromLocationUpdate(base, <String, dynamic>{
        'lat': 1.001,
        'lon': 2.0,
        'speed_mps': 21.3,
        'heading_deg': 10,
        'ts': '2026-01-01T12:00:01Z',
      });
      expect(fresh.speedMps, 21.3);
      expect(fresh.headingDeg, 10);
      final Member noSpeed = memberFromLocationUpdate(fresh, <String, dynamic>{
        'lat': 1.002,
        'lon': 2.0,
        'ts': '2026-01-01T12:00:02Z',
      });
      expect(noSpeed.speedMps, isNull);
      expect(noSpeed.headingDeg, 10, reason: 'last known heading is kept');
    });

    test('heading is normalised and garbage is ignored', () {
      expect(
        memberFromJson(<String, dynamic>{'id': 'a', 'heading_deg': -90}).headingDeg,
        270,
      );
      expect(
        memberFromJson(<String, dynamic>{'id': 'a', 'heading_deg': 725}).headingDeg,
        5,
      );
    });

    test('speeding uses the displayed (rounded) mph', () {
      expect(isSpeedingMps(31.2), isTrue); // 69.8 mph rounds to 70
      expect(isSpeedingMps(31.0), isFalse); // 69.35 mph rounds to 69
      expect(isSpeedingMps(null), isFalse);
    });
  });
}
