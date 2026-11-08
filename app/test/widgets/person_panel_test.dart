import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/member_day_service.dart';
import 'package:openfamily/services/place_alert_rules_service.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/weekly_summary_service.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/person_panel.dart';

class _Alerts implements MemberPlaceAlertsApi {
  _Alerts({this.on = true, this.fail = false});
  bool on;
  bool fail;
  final List<String> sets = <String>[];

  @override
  Future<bool> enabled(String memberId) async => on;

  @override
  Future<void> setEnabled(String memberId, bool value) async {
    sets.add('$memberId:$value');
    if (fail) throw Exception('boom');
    on = value;
  }
}

class _Weekly implements WeeklySummaryApi {
  _Weekly(this.cur, this.prev);
  final WeekStat cur;
  final WeekStat prev;
  @override
  Future<WeeklySummary> load() async => WeeklySummary(members: <WeeklyMember>[
        WeeklyMember(userId: 'u1', name: 'Sam', current: cur, previous: prev),
      ]);
}

final DateTime _now = DateTime(2026, 11, 5, 12);

Member _m({
  MemberStatus status = MemberStatus.normal,
  DateTime? seen,
  String? phone,
  MovementType movement = MovementType.none,
}) =>
    Member(
      id: 'u1',
      name: 'Sam',
      position: const LatLng(37.77, -122.41),
      status: status,
      batteryPercent: 50,
      address: '4th St',
      movement: movement,
      lastSeen: seen ?? _now,
      phone: phone,
    );

Future<void> _pump(
  WidgetTester t,
  Member m, {
  _Alerts? alerts,
  WeeklySummaryApi? weekly,
  List<Uri>? launched,
  String? selfId,
  LatLng? me,
  VoidCallback? onMessage,
  MemberDayLoader? day,
}) async {
  t.view.physicalSize = const Size(390, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: PersonPanel(
        member: m,
        controller: ScrollController(),
        onClose: () {},
        selfId: selfId,
        myPosition: me,
        onMessage: onMessage,
        alerts: alerts ?? _Alerts(),
        weekly: weekly ?? _Weekly(const WeekStat(), const WeekStat()),
        dayLoader: day ?? (_, __) async => const MemberDay(),
        launcher: (Uri u) async {
          launched?.add(u);
          return true;
        },
        now: _now,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => UnitPreferenceService.units.value = UnitSystem.imperial);

  testWidgets('shows name, last updated and no banner when fresh', (t) async {
    await _pump(t, _m(seen: _now.subtract(const Duration(minutes: 5))));
    expect(find.byKey(const Key('person_name')), findsOneWidget);
    expect(find.text('Last updated 5 min ago'), findsOneWidget);
    expect(find.byKey(const Key('person_stale_banner')), findsNothing);
  });

  testWidgets('stale member shows the location is not updating banner',
      (t) async {
    await _pump(
        t,
        _m(
            status: MemberStatus.stopped,
            seen: _now.subtract(const Duration(hours: 1))));
    expect(find.byKey(const Key('person_stale_banner')), findsOneWidget);
    expect(find.text('Sam’s location isn’t updating'), findsOneWidget);
    expect(find.text('Last updated 1 hr. ago'), findsOneWidget);
  });

  testWidgets('place alert switch loads and saves through the service',
      (t) async {
    final _Alerts a = _Alerts(on: true);
    await _pump(t, _m(), alerts: a);
    Switch sw() =>
        t.widget<Switch>(find.byKey(const Key('person_place_alerts_switch')));
    expect(sw().value, isTrue);
    expect(find.text('if Sam leaves or arrives'), findsOneWidget);
    expect(find.byKey(const Key('person_customize_places')), findsOneWidget);

    await t.tap(find.byKey(const Key('person_place_alerts_switch')));
    await t.pumpAndSettle();
    expect(a.sets, <String>['u1:false']);
    expect(sw().value, isFalse);
    expect(find.byKey(const Key('person_customize_places')), findsNothing);
  });

  testWidgets('a failed save puts the switch back', (t) async {
    final _Alerts a = _Alerts(on: true, fail: true);
    await _pump(t, _m(), alerts: a);
    await t.tap(find.byKey(const Key('person_place_alerts_switch')));
    await t.pumpAndSettle();
    expect(
        t.widget<Switch>(find.byKey(const Key('person_place_alerts_switch'))).value,
        isTrue);
    expect(find.text('Could not save that. Try again.'), findsOneWidget);
  });

  testWidgets('own panel has no alert switch or person actions', (t) async {
    await _pump(t, _m(phone: '+15550001'), selfId: 'u1');
    expect(find.byKey(const Key('person_place_alerts_switch')), findsNothing);
    expect(find.text('Call'), findsNothing);
    expect(find.text('Message'), findsNothing);
  });

  testWidgets('weekly metrics show counts and trend vs last week', (t) async {
    await _pump(
      t,
      _m(),
      weekly: _Weekly(
        const WeekStat(drives: 4, distanceM: 16093.44, speeding: 3, hardBrake: 1, rapidAccel: 2),
        const WeekStat(speeding: 1, hardBrake: 1, rapidAccel: 5),
      ),
    );
    String count(String k) => t
        .widget<Text>(find.descendant(
            of: find.byKey(Key('person_metric_$k')),
            matching: find.byKey(const Key('metric_count'))))
        .data!;
    expect(count('speeding'), '3');
    expect(count('braking'), '1');
    expect(count('accel'), '2');
    expect(count('distracted'), '–');
    expect(
        find.descendant(
            of: find.byKey(const Key('person_metric_speeding')),
            matching: find.byIcon(Icons.trending_up)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('person_metric_accel')),
            matching: find.byIcon(Icons.trending_down)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('person_metric_braking')),
            matching: find.byIcon(Icons.arrow_right_alt)),
        findsOneWidget);
    expect(find.text('Since Mon, Nov 2'), findsOneWidget);
    expect(find.text('4 drives · 10 mi'), findsOneWidget);
  });

  testWidgets('distance pill uses the unit setting; Call needs a phone',
      (t) async {
    final List<Uri> launched = <Uri>[];
    await _pump(t, _m(phone: '+15551234'),
        me: const LatLng(37.77, -122.41), launched: launched);
    expect(find.text('0.0 mi'), findsNothing);
    expect(find.text('Call'), findsOneWidget);
    await t.tap(find.text('Call'));
    await t.pump();
    expect(launched.single.scheme, 'tel');
    expect(launched.single.path, '+15551234');

    UnitPreferenceService.setForTest(UnitSystem.metric);
    await _pump(t, _m(), me: const LatLng(37.77, -122.31));
    expect(find.text('Call'), findsNothing);
    expect(find.textContaining('km'), findsWidgets);
  });

  testWidgets('Message uses the host chat callback', (t) async {
    int opened = 0;
    await _pump(t, _m(), onMessage: () => opened++);
    await t.tap(find.text('Message'));
    expect(opened, 1);
  });

  testWidgets('Today card lists trips and an empty state', (t) async {
    await _pump(t, _m());
    expect(find.byKey(const Key('person_today_empty')), findsOneWidget);
  });
}
