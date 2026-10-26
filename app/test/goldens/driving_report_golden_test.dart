import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_report_fixtures.dart';

/// Golden renders of the weekly driving report. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens/driving_report_golden_test.dart`.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

Future<void> _loadFonts() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final String dir = '$root/bin/cache/artifacts/material_fonts';
  final FontLoader roboto = FontLoader('Roboto');
  for (final String n in <String>['Roboto-Regular', 'Roboto-Bold']) {
    final File f = File('$dir/$n.ttf');
    if (f.existsSync()) {
      roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
  }
  await roboto.load();
  final File icons = File('$dir/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final FontLoader il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

Widget _app(Widget home, ThemeData theme, double scale) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
      ),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontFamily: 'Roboto'),
          child: child!,
        ),
      ),
      home: home,
    );

void _golden(
  String name,
  Widget Function() screen, {
  double scale = 1,
  bool settle = true,
  Future<void> Function(WidgetTester)? after,
}) {
  for (final bool dark in <bool>[false, true]) {
    final String file = '${name}_${dark ? 'dark' : 'light'}'
        '${scale == 1 ? '' : '_x${scale.toStringAsFixed(0)}'}';
    testWidgets('golden $file', (WidgetTester t) async {
      t.view.physicalSize = const Size(780, 1688);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        _app(screen(), dark ? buildDarkTheme() : buildLightTheme(), scale),
      );
      // Let asset images (logo) decode before the first frame is captured.
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      if (settle) {
        await t.pumpAndSettle();
      } else {
        await t.pump(const Duration(milliseconds: 100));
      }
      if (after != null) await after(t);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('$file.png'));
    }, skip: !_on);
  }
}



Member _m(String id, String name, Color c) => Member(
  id: id,
  name: name,
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
  avatarColor: c,
);

Widget _screen(FakeTripReportApi api) => FamilyDrivingReportScreen(
  members: ValueNotifier<List<Member>>(<Member>[
    _m('u1', 'Blake', const Color(0xFF0284C7)),
    _m('u2', 'Brian', const Color(0xFF7C3AED)),
  ]),
  userId: ValueNotifier<String?>(null),
  api: api,
  clock: () => DateTime(2026, 10, 26, 9),
);

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  _golden(
    'evt_report',
    () => _screen(FakeTripReportApi(result: reportJson(twoMembers: true, speeding: 2))),
  );
  _golden(
    'evt_report',
    () => _screen(FakeTripReportApi(result: reportJson(twoMembers: true, speeding: 2))),
    scale: 2,
  );
  _golden(
    'evt_report_empty',
    () => _screen(FakeTripReportApi(result: reportJson(drives: 0, speeding: 0))),
  );
  _golden(
    'evt_report_sheet',
    () => _screen(FakeTripReportApi(result: reportJson(twoMembers: true, speeding: 3))),
    after: (WidgetTester t) async {
      await t.tap(find.text('Speeding'));
      await t.pumpAndSettle();
    },
  );
}
