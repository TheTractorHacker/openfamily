import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/circle_create_screen.dart';
import 'package:openfamily/screens/circle_detail_screen.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/services/circle_selection.dart';
import 'package:openfamily/widgets/circle_widgets.dart';

import 'circles_screens_test.dart' show FakeCircleService;

class _MemStore implements CircleSelectionStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String? circleId) async {}
}

Circle _trip({String role = 'admin', Duration left = const Duration(days: 2, hours: 3)}) =>
    Circle(
      id: 'trip',
      name: 'Road trip',
      role: role,
      sharingEnabled: true,
      memberCount: 2,
      expiresAt: DateTime.now().toUtc().add(left),
    );

Widget _app(Widget home) => MaterialApp(key: UniqueKey(), home: home);

void main() {
  test('model parses expires_at and reports expiry', () {
    final Circle c = Circle.fromJson(<String, dynamic>{
      'id': 'a',
      'expires_at': '2030-01-02T03:04:05Z',
    });
    expect(c.isTemporary, isTrue);
    expect(c.isExpiredAt(DateTime.utc(2030, 1, 3)), isTrue);
    expect(c.isExpiredAt(DateTime.utc(2030, 1, 1)), isFalse);
    expect(Circle.fromJson(<String, dynamic>{'id': 'b'}).isTemporary, isFalse);
  });

  test('countdown label rounds down to the largest unit', () {
    final DateTime now = DateTime.utc(2030, 1, 1);
    expect(circleTimeLeftLabel(now.add(const Duration(days: 2, hours: 5)), now),
        'Ends in 2 days');
    expect(circleTimeLeftLabel(now.add(const Duration(days: 1)), now),
        'Ends in 1 day');
    expect(circleTimeLeftLabel(now.add(const Duration(hours: 5)), now),
        'Ends in 5 hours');
    expect(circleTimeLeftLabel(now.add(const Duration(minutes: 20)), now),
        'Ends in 20 min');
    expect(circleTimeLeftLabel(now.subtract(const Duration(seconds: 1)), now),
        'Ended');
  });

  test('selection falls back to the primary circle when the selected one expires',
      () {
    final DateTime now = DateTime.utc(2030, 1, 1);
    final CircleSelection sel = CircleSelection(store: _MemStore());
    const Circle home = Circle(
        id: 'home',
        name: 'Home',
        role: 'admin',
        sharingEnabled: true,
        memberCount: 2,
        isPrimary: true);
    final Circle trip = Circle(
        id: 'trip',
        name: 'Trip',
        role: 'member',
        sharingEnabled: true,
        memberCount: 3,
        expiresAt: now.add(const Duration(hours: 1)));
    sel.update(<Circle>[home, trip]);
    sel.select('trip');
    expect(sel.effectiveId, 'trip');
    expect(sel.nextExpiry(now), trip.expiresAt);
    expect(sel.pruneExpired(now), isFalse);
    expect(sel.pruneExpired(now.add(const Duration(hours: 2))), isTrue);
    expect(sel.selectedId, 'home');
    expect(sel.circles.map((Circle c) => c.id), <String>['home']);
  });

  testWidgets('list shows a countdown chip on a temporary circle only',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    svc.circles = <Circle>[svc.circles.first, _trip()];
    await tester.pumpWidget(_app(CirclesScreen(service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('Ends in 2 days'), findsOneWidget);
    expect(find.byType(CircleCountdownChip), findsOneWidget);
  });

  testWidgets('create flow: Temporary toggle sends the chosen duration',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(_app(CircleCreateScreen(service: svc)));
    expect(find.text('LASTS FOR'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Beach week');
    await tester.tap(find.text('Temporary'));
    await tester.pumpAndSettle();
    expect(find.text('LASTS FOR'), findsOneWidget);
    await tester.tap(find.text('3 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create circle'));
    await tester.pumpAndSettle();
    expect(svc.calls.single, startsWith('create:Beach week:'));
    expect(svc.calls.single, endsWith(':72'));
  });

  testWidgets('create flow without Temporary sends no duration',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(_app(CircleCreateScreen(service: svc)));
    await tester.enterText(find.byType(TextField), 'Family');
    await tester.tap(find.text('Create circle'));
    await tester.pumpAndSettle();
    expect(svc.calls.single, endsWith(':-'));
  });

  testWidgets('admin can extend and end a temporary circle; member cannot',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(
        _app(CircleDetailScreen(circle: _trip(), service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('Extend / End now'), findsOneWidget);
    await tester.tap(find.text('Extend / End now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Extend by 3 days'));
    await tester.pumpAndSettle();
    expect(svc.calls, contains('extend:trip:72'));

    await tester.tap(find.text('Extend / End now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End now').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('End now').last);
    await tester.pumpAndSettle();
    expect(svc.calls, contains('end:trip'));

    svc.calls.clear();
    svc.members = <CircleMember>[
      const CircleMember(
          userId: 'me', name: 'Alex', role: 'member', sharingEnabled: true),
    ];
    await tester.pumpWidget(_app(CircleDetailScreen(
        key: UniqueKey(), circle: _trip(role: 'member'), service: svc)));
    await tester.pumpAndSettle();
    expect(find.byType(CircleCountdownChip), findsOneWidget);
    expect(find.text('Extend / End now'), findsNothing);
  });
}
