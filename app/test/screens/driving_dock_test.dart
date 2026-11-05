import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/driving_member_dock.dart';
import 'package:openfamily/widgets/driving_report_cards.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_report_fixtures.dart';

Member _m(String id, String n) => Member(
  id: id,
  name: n,
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'driving_detection_disclosure_seen': true,
    });
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  testWidgets('member dock never covers the last card at 412dp', (t) async {
    t.view.physicalSize = const Size(412 * 2, 780 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: FamilyDrivingReportScreen(
          members: ValueNotifier<List<Member>>(<Member>[
            _m('u1', 'Blake'),
            _m('u2', 'Brian'),
          ]),
          userId: ValueNotifier<String?>('u1'),
          api: FakeTripReportApi(result: reportJson(twoMembers: true, speeding: 2)),
          clock: () => DateTime(2026, 10, 26, 9),
          detectionLoader: () async => true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(DrivingMemberDock), findsOneWidget);
    await t.drag(find.byType(ListView), const Offset(0, -3000));
    await t.pumpAndSettle();
    final Rect dock = t.getRect(find.byType(DrivingMemberDock));
    final Rect list = t.getRect(find.byType(ListView));
    expect(list.bottom, lessThanOrEqualTo(dock.top + 0.01));
    for (final Element e in find.byType(MemberDrivingCard).evaluate()) {
      final Rect r = t.getRect(find.byWidget(e.widget));
      if (r.bottom > 0) expect(r.bottom, lessThanOrEqualTo(dock.top + 0.01));
    }
  });
}
