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

/// Golden renders of the Driving page. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens/driving_page_golden_test.dart`.
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
  void Function()? before,
}) {
  for (final bool dark in <bool>[false, true]) {
    final String file = '${name}_${dark ? 'dark' : 'light'}'
        '${scale == 1 ? '' : '_x${scale.toStringAsFixed(0)}'}';
    testWidgets('golden $file', (WidgetTester t) async {
      t.view.physicalSize = const Size(780, 3000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      before?.call();
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



Member _m(String id, String name, Color c, {bool driving = false}) => Member(
  id: id,
  name: name,
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
  avatarColor: c,
  movement: driving ? MovementType.car : MovementType.none,
  speedMph: driving ? 42 : null,
);

final DateTime _clock = DateTime(2026, 10, 25, 12);

Widget _screen(
  Map<String, dynamic> json, {
  List<Member>? members,
  bool detectionOn = true,
}) => FamilyDrivingReportScreen(
  members: ValueNotifier<List<Member>>(
    members ??
        <Member>[
          _m('u1', 'Blake', const Color(0xFF0284C7)),
          _m('u2', 'Brian', const Color(0xFF7C3AED)),
        ],
  ),
  userId: ValueNotifier<String?>('u1'),
  api: FakeTripReportApi(result: json),
  clock: () => _clock,
  detectionLoader: () async => detectionOn,
);

/// One member, one drive.
Map<String, dynamic> _oneDrive() {
  final Map<String, dynamic> j = reportJson(rich: true, speeding: 1);
  (j['members'] as List).removeLast();
  j['recent_trips'] = (j['recent_trips'] as List).sublist(0, 1);
  (j['recent_trips'] as List).first['user_id'] = 'u1';
  j['days'] = <Map<String, dynamic>>[
    for (int i = 0; i < 7; i++)
      <String, dynamic>{
        'date': '2026-10-${19 + i}',
        'drives': i == 6 ? 1 : 0,
        'distance_m': i == 6 ? 48000.0 : 0.0,
        'top_speed_mps': i == 6 ? 37.5 : 0.0,
      },
  ];
  return j;
}

/// A busy week: three members, ten drives, one idle member.
Map<String, dynamic> _busy() {
  final Map<String, dynamic> j = reportJson(
    rich: true,
    twoMembers: true,
    speeding: 3,
    hardBrake: 2,
    drives: 9,
    sensor: true,
  );
  const List<double> km = <double>[22000, 31000, 12000, 41000, 58000, 9000, 24000];
  j['days'] = <Map<String, dynamic>>[
    for (int i = 0; i < 7; i++)
      <String, dynamic>{
        'date': '2026-10-${19 + i}',
        'drives': i == 5 ? 1 : 2,
        'distance_m': km[i],
        'top_speed_mps': 24.0 + i * 2,
      },
  ];
  final List<Map<String, dynamic>> trips = <Map<String, dynamic>>[];
  for (int i = 0; i < 10; i++) {
    final int day = 25 - i ~/ 2;
    trips.add(<String, dynamic>{
      'id': 't$i',
      'user_id': i.isEven ? 'u1' : 'u2',
      'name': i.isEven ? 'Blake' : 'Brian',
      'started_at': '2026-10-${day}T${i.isEven ? '07:52' : '17:10'}:00',
      'ended_at': '2026-10-${day}T${i.isEven ? '08:20' : '17:40'}:00',
      'distance_m': 9000.0 + i * 1300,
      'duration_s': 1680,
      'max_speed_mps': 24.0 + i,
      'mode': 'driving',
      'event_counts': <String, dynamic>{
        'speeding': i % 4 == 0 ? 1 : 0,
        'hard_brake': i % 3 == 0 ? 2 : 0,
        'rapid_accel': 0,
        'phone_use': 0,
      },
    });
  }
  j['recent_trips'] = trips;
  (j['members'] as List).add(<String, dynamic>{
    'user_id': 'u3',
    'name': 'Sam',
    'drives': 0,
    'distance_m': 0,
    'top_speed_mps': null,
    'events': <String, dynamic>{
      'speeding': 0, 'hard_brake': 0, 'rapid_accel': 0, 'phone_use': 0,
    },
    'previous_events': <String, dynamic>{
      'speeding': 0, 'hard_brake': 0, 'rapid_accel': 0, 'phone_use': 0,
    },
  });
  return j;
}

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    // Disclosure already seen unless a test says otherwise.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'driving_detection_disclosure_seen': true,
    });
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  for (final double scale in <double>[1, 2]) {
    _golden('drv_one_drive', () => _screen(_oneDrive()), scale: scale);
    _golden(
      'drv_busy_week',
      () => _screen(
        _busy(),
        members: <Member>[
          _m('u1', 'Blake', const Color(0xFF0284C7), driving: true),
          _m('u2', 'Brian', const Color(0xFF7C3AED)),
          _m('u3', 'Sam', const Color(0xFF16A34A)),
        ],
      ),
      scale: scale,
    );
    _golden(
      'drv_empty_week',
      () => _screen(reportJson(drives: 0, speeding: 0, rich: true)),
      scale: scale,
    );
    _golden(
      'drv_detection_off',
      () => _screen(_oneDrive(), detectionOn: false),
      scale: scale,
    );
  }
  _golden('drv_disclosure', () => _screen(_oneDrive()), scale: 1,
      before: () => SharedPreferences.setMockInitialValues(<String, Object>{}));
  _golden('drv_disclosure', () => _screen(_oneDrive()), scale: 2,
      before: () => SharedPreferences.setMockInitialValues(<String, Object>{}));
}
