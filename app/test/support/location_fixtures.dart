import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';

const Member kDriver = Member(
  id: 'u1',
  name: 'Sam',
  position: LatLng(37.77, -122.41),
  status: MemberStatus.normal,
  batteryPercent: 64,
  address: '4th St',
  movement: MovementType.car,
  speedMph: 42,
);

const Member kAtHome = Member(
  id: 'u2',
  name: 'Maya',
  position: LatLng(37.78, -122.42),
  status: MemberStatus.normal,
  batteryPercent: 18,
  address: '12 Oak Ave',
  movement: MovementType.home,
);

const Member kSelf = Member(
  id: 'me',
  name: 'You',
  position: LatLng(37.775, -122.418),
  status: MemberStatus.normal,
  batteryPercent: 90,
  address: 'Market St',
);

const Member kOffline = Member(
  id: 'u4',
  name: 'Grandpa',
  position: null,
  status: MemberStatus.stopped,
  batteryPercent: 0,
  address: '',
);

const List<Circle> kCircles = <Circle>[
  Circle(
    id: 'c1',
    name: 'Frank Family',
    role: 'admin',
    sharingEnabled: true,
    memberCount: 4,
    isPrimary: true,
  ),
  Circle(
    id: 'c2',
    name: 'Soccer team',
    role: 'member',
    sharingEnabled: false,
    memberCount: 11,
  ),
];

Future<List<Place>> fakePlaces() async => const <Place>[
  Place(
    id: 'p1',
    name: 'Home',
    icon: Icons.home,
    address: '12 Oak Ave',
    position: LatLng(37.78, -122.42),
    radiusMeters: 150,
    type: 'home',
  ),
  Place(
    id: 'p2',
    name: 'School',
    icon: Icons.school,
    address: '',
    position: LatLng(37.79, -122.43),
    radiusMeters: 200,
    type: 'school',
  ),
];

/// A stand-in for the real tile map: flat colour with a few "roads".
class FakeMap extends StatelessWidget {
  const FakeMap({super.key});

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(child: CustomPaint(painter: _FakeMapPainter()));
}

class _FakeMapPainter extends CustomPainter {
  const _FakeMapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFE8E4DC),
    );
    final Paint road = Paint()
      ..color = Colors.white
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, size.height * .3),
      Offset(size.width, size.height * .45),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .4, 0),
      Offset(size.width * .55, size.height),
      road,
    );
    canvas.drawCircle(
      Offset(size.width * .5, size.height * .38),
      22,
      Paint()..color = const Color(0xFF8FD400),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
