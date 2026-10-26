// Portable measurement (uses only API present before and after the change):
// how many widgets rebuild while the People sheet is dragged.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:openfamily/widgets/location_tab_view.dart';

import '../support/build_counter.dart';
import '../support/location_fixtures.dart';

List<Member> roster(int n) => <Member>[
      for (int i = 0; i < n; i++)
        Member(
          id: 'm$i',
          name: 'Person $i',
          position: LatLng(37.77 + i * 0.01, -122.41),
          status: MemberStatus.normal,
          batteryPercent: 80,
          address: 'Street $i',
        ),
    ];

void main() {
  testWidgets('dragging the sheet rebuilds no rows or floating buttons', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: LocationTabView(
        map: const FakeMap(),
        circleName: 'Family',
        members: roster(10),
        selfId: 'm0',
        placesLoader: fakePlaces,
      ),
    ));
    await tester.pump();
    // Open the sheet so the rows are on screen.
    await tester.fling(find.text('People'), const Offset(0, -500), 2000);
    await tester.pumpAndSettle();

    final BuildCounter c = BuildCounter()..start();
    final TestGesture g =
        await tester.startGesture(tester.getCenter(find.byType(DsDragHandle)));
    for (int i = 0; i < 40; i++) {
      await g.moveBy(Offset(0, i.isEven ? 6 : -6));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    c.stop();

    // ignore: avoid_print
    print('PERFMETRIC sheet-drag(40 frames,10 rows): '
        'PersonRow=${c.of('_PersonRow')} DsListRow=${c.of('DsListRow')} '
        'StatusAvatar=${c.of('StatusAvatar')} DsPillButton=${c.of('DsPillButton')} '
        'LocationTabView=${c.of('LocationTabView')}');
    expect(c.of('_PersonRow'), 0);
    expect(c.of('DsListRow'), 0);
    expect(c.of('DsPillButton'), 0, reason: 'floating row is a cached child');
  });
}
