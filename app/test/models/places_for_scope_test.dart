import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/services/member_mapper.dart';

Place _p(String id, String? circle, {LatLng pos = const LatLng(52, 4)}) => Place(
      id: id,
      name: id,
      icon: Icons.place,
      address: '',
      position: pos,
      radiusMeters: 150,
      circleId: circle,
    );

void main() {
  final List<Place> all = <Place>[
    _p('Family home', null),
    _p('Work (circle A)', 'A'),
    _p('Gym (circle B)', 'B'),
  ];

  test('a circle sees whole-family places and its own, not other circles\'', () {
    expect(placesForScope(all, 'A').map((Place p) => p.id),
        <String>['Family home', 'Work (circle A)']);
  });

  test('no single circle (legacy / All) keeps every place', () {
    expect(placesForScope(all, null).length, 3);
    expect(placesForScope(all, 'all').length, 3);
  });

  test('a member in circle A is never labelled with a circle-B place', () {
    const Member m = Member(
      id: 'u',
      name: 'U',
      position: LatLng(52, 4),
      status: MemberStatus.normal,
      batteryPercent: 80,
      address: 'Somewhere',
    );
    final List<Place> onlyB = <Place>[_p('Gym (circle B)', 'B')];
    expect(applyPlaceAddress(m, placesForScope(onlyB, 'A')).address, 'Somewhere');
    expect(applyPlaceAddress(m, placesForScope(onlyB, 'B')).address, 'Gym (circle B)');
  });
}
