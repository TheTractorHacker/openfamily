import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/widgets/member_tile.dart';

/// A driving, speeding member with an ETA — exercises the chips which are the
/// meatiest part of [MemberTile].
const Member _driver = Member(
  id: 'sam',
  name: 'Sam',
  position: null,
  status: MemberStatus.normal,
  batteryPercent: 88,
  address: 'The Gym',
  movement: MovementType.car,
  speedMph: 74, // >= kSpeedingMph => speeding amber chip
  eta: '12m',
);

const Member _stopped = Member(
  id: 'ella',
  name: 'Ella',
  position: null,
  status: MemberStatus.stopped,
  batteryPercent: 0,
  address: 'Work',
);

const Member _noLocation = Member(
  id: 'lea',
  name: 'Lea',
  position: null,
  status: MemberStatus.normal,
  batteryPercent: 60,
  address: 'Unknown road',
);

Widget _host(Member member) {
  return MaterialApp(
    home: Scaffold(body: MemberTile(member: member, onTap: () {})),
  );
}

void main() {
  testWidgets('driving member shows battery %, ETA, and driving speed chips', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_driver));

    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('88%'), findsOneWidget);
    expect(find.text('ETA 12m'), findsOneWidget);
    expect(find.text('74 mph'), findsOneWidget);
    // No "Offline" chip since battery is present.
    expect(find.text('Offline'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopped member with no battery falls back to Offline chip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_stopped));

    expect(find.text('Ella'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no position shows the no-location placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_noLocation));

    expect(find.text('No location yet'), findsOneWidget);
    expect(find.text('Unknown road'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tile invokes onTap', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MemberTile(member: _driver, onTap: () => taps++)),
      ),
    );
    await tester.tap(find.text('Sam'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('parked member with place presence shows the arrival line', (
    WidgetTester tester,
  ) async {
    final Member m = Member(
      id: 'amy',
      name: 'Amy',
      position: const LatLng(1, 2),
      status: MemberStatus.normal,
      batteryPercent: 70,
      address: 'Stationary',
      placePresence: PlacePresence(
        placeId: 'p',
        placeName: 'Home',
        isAt: true,
        since: DateTime.now(),
      ),
    );
    await tester.pumpWidget(_host(m));
    expect(find.textContaining('At Home since'), findsOneWidget);
    expect(find.text('Stationary'), findsNothing);
  });
}
