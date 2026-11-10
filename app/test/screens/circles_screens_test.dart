import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/circle_detail_screen.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart';

import '../support/fake_processing_controller.dart';
import 'package:openfamily/theme/app_theme.dart';

class FakeCircleService implements CircleService {
  List<Circle> circles = <Circle>[
    const Circle(
        id: 'c1',
        name: 'Home',
        icon: '🏠',
        role: 'admin',
        sharingEnabled: true,
        memberCount: 2),
    const Circle(
        id: 'c2',
        name: 'Friends',
        role: 'member',
        sharingEnabled: false,
        memberCount: 3),
  ];
  List<CircleMember> members = <CircleMember>[
    const CircleMember(
        userId: 'me', name: 'Alex', role: 'admin', sharingEnabled: true),
    const CircleMember(
        userId: 'u2', name: 'Sam', role: 'member', sharingEnabled: true),
  ];
  Object? listError;
  Object? sharingError;
  Object? deleteError;
  Object? leaveError;
  final List<String> calls = <String>[];

  @override
  Future<String> myUserId() async => 'me';
  @override
  Future<List<Circle>> listCircles() async {
    if (listError != null) throw listError!;
    return circles;
  }

  @override
  Future<Circle> createCircle(String name, String? icon,
      {int? durationHours}) async {
    calls.add('create:$name:$icon:${durationHours ?? '-'}');
    return Circle(
        id: 'new',
        name: name,
        icon: icon,
        role: 'admin',
        sharingEnabled: true,
        memberCount: 1);
  }

  @override
  Future<Circle> extendCircle(String id, int hours) async {
    calls.add('extend:$id:$hours');
    return Circle(
        id: id,
        name: 'Trip',
        role: 'admin',
        sharingEnabled: true,
        memberCount: 2,
        expiresAt: DateTime.now().toUtc().add(Duration(hours: hours + 24)));
  }

  @override
  Future<void> endCircle(String id) async {
    calls.add('end:$id');
  }

  @override
  Future<void> updateCircle(String id, {String? name, String? icon}) async {
    calls.add('update:$name');
  }

  @override
  Future<void> deleteCircle(String id, {bool force = false}) async {
    calls.add('delete:$id:$force');
    if (deleteError != null && !force) throw deleteError!;
  }

  @override
  Future<List<CircleMember>> listMembers(String id) async => members;
  @override
  Future<void> removeMember(String id, String userId) async {
    calls.add('remove:$userId');
    if (leaveError != null) throw leaveError!;
  }

  @override
  Future<void> setRole(String id, String userId, String role) async {
    calls.add('role:$userId:$role');
  }

  @override
  Future<void> setSharing(String id, bool enabled) async {
    calls.add('sharing:$enabled');
    if (sharingError != null) throw sharingError!;
  }

  @override
  Future<List<CircleInvite>> listInvites(String id) async => <CircleInvite>[
        const CircleInvite(
            id: 'i1', code: 'ABC123', role: 'member', maxUses: 5, uses: 1),
      ];
  @override
  Future<CircleInvite> createInvite(String id) async => const CircleInvite(
      id: 'i2', code: 'NEW999', role: 'member', maxUses: 5, uses: 0);
  @override
  Future<void> revokeInvite(String id, String inviteId) async {
    calls.add('revoke:$inviteId');
  }

  @override
  Future<String> joinCircle(String code) async => 'c3';
}

Widget _app(Widget home, {ThemeData? theme}) =>
    MaterialApp(theme: theme, home: home);

Circle _circle(FakeCircleService s, int i) => s.circles[i];

void main() {
  testWidgets('list shows circles with role badges and sharing status',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(_app(CirclesScreen(service: svc)));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
    expect(find.text('Sharing'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('list renders empty, offline and error states',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService()..circles = <Circle>[];
    await tester.pumpWidget(_app(CirclesScreen(service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('No circles yet'), findsOneWidget);

    svc.listError = const CircleException('x', offline: true);
    await tester.pumpWidget(_app(CirclesScreen(key: UniqueKey(), service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('You\'re offline'), findsOneWidget);

    svc.listError = const CircleException('Boom', status: 500);
    svc.circles = <Circle>[];
    await tester.pumpWidget(_app(CirclesScreen(key: UniqueKey(), service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t load circles'), findsOneWidget);
    expect(find.text('Boom'), findsOneWidget);
  });

  testWidgets('sharing toggle takes effect at once and reverts on failure',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(
        _app(CircleDetailScreen(circle: _circle(svc, 0), service: svc)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sharing: members'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.textContaining('Paused: nobody'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(svc.calls, contains('sharing:false'));

    svc.sharingError = const CircleException('nope', status: 500);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    // Server refused turning it back on; stays paused (reload returns the
    // server's view, which the fake still reports as sharing -> rolled back).
    expect(find.text('nope'), findsOneWidget);
  });

  testWidgets('admin sees management controls; member does not',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(
        _app(CircleDetailScreen(circle: _circle(svc, 0), service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Alex (you)'), findsOneWidget);
    expect(find.byTooltip('Manage Sam'), findsOneWidget);
    expect(find.text('ABC123'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Delete circle'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Delete circle'), findsOneWidget);

    svc.members = <CircleMember>[
      const CircleMember(
          userId: 'me', name: 'Alex', role: 'member', sharingEnabled: true),
      const CircleMember(
          userId: 'u2', name: 'Sam', role: 'admin', sharingEnabled: true),
    ];
    await tester.pumpWidget(_app(CircleDetailScreen(
        key: UniqueKey(), circle: _circle(svc, 1), service: svc)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Manage Sam'), findsNothing);
    expect(find.text('Invite codes'), findsNothing);
    await tester.scrollUntilVisible(find.text('Leave circle'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Delete circle'), findsNothing);
  });

  testWidgets('role change and removal call the service',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(
        _app(CircleDetailScreen(circle: _circle(svc, 0), service: svc)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Manage Sam'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make admin'));
    await tester.pumpAndSettle();
    expect(svc.calls, contains('role:u2:admin'));

    await tester.tap(find.byTooltip('Manage Sam'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from circle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(svc.calls, contains('remove:u2'));
  });

  testWidgets('delete shows server refusal and can be forced',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService()
      ..deleteError = const CircleException(
          'circle is the only circle of some members; pass force=true to delete anyway',
          status: 409);
    await tester.pumpWidget(_app(Builder(
        builder: (BuildContext c) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
                      builder: (_) => CircleDetailScreen(
                          circle: _circle(svc, 0), service: svc))),
                  child: const Text('open')),
            ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Delete circle'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Delete circle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete circle').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('only circle of some members'), findsOneWidget);
    await tester.tap(find.text('Delete anyway'));
    await tester.pumpAndSettle();
    expect(svc.calls, containsAll(<String>['delete:c1:false', 'delete:c1:true']));
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('last admin leaving shows the server message and stays',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService()
      ..leaveError = const CircleException(
          'cannot remove or leave as the last admin',
          status: 409);
    await tester.pumpWidget(
        _app(CircleDetailScreen(circle: _circle(svc, 0), service: svc)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Leave circle'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Leave circle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('cannot remove or leave as the last admin'),
        findsOneWidget);
    expect(find.byType(CircleDetailScreen), findsOneWidget);
  });

  testWidgets('renders in dark theme at large text without overflow',
      (WidgetTester tester) async {
    final FakeCircleService svc = FakeCircleService();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark().copyWith(extensions: <ThemeExtension<dynamic>>[
        BrandTheme.night,
      ]),
      builder: (BuildContext c, Widget? w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
        child: w!,
      ),
      home: CircleDetailScreen(circle: _circle(svc, 0), service: svc),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('Require server processing (owner switch)', () {
    Future<FakeProcessingController> pump(WidgetTester tester, FakeCircleService svc, ProcessingSnapshot snap, {String mode = 'private'}) async {
      final FakeProcessingController c = FakeProcessingController(snap);
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final Circle circle = _circle(svc, 0).copyWith(e2eeMode: mode);
      await tester.pumpWidget(_app(CircleDetailScreen(circle: circle, service: svc, processing: c)));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the admin of a Private circle with a server key sees one switch with the plain explanation; it calls setRequireServer',
        (WidgetTester tester) async {
      final FakeCircleService svc = FakeCircleService();
      final FakeProcessingController c = await pump(tester, svc, FakeProcessingController.snapshot());
      expect(find.byKey(const Key('circle-require-server')), findsOneWidget);
      expect(find.text('Require server processing'), findsOneWidget);
      expect(find.text("Everyone's phone sends its location to your Orbitly server for processing. Members cannot turn it off."), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const Key('circle-require-server')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(c.calls, contains('require:true'));
      final Switch sw = tester.widget<Switch>(find.descendant(of: find.byKey(const Key('circle-require-server')), matching: find.byType(Switch)));
      expect(sw.value, isTrue);
      await tester.tap(find.descendant(of: find.byKey(const Key('circle-require-server')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(c.calls, contains('require:false'));
    });

    testWidgets('hidden for a member, a normal circle, and without a server key', (WidgetTester tester) async {
      final FakeCircleService svc = FakeCircleService();
      await pump(tester, svc, FakeProcessingController.snapshot(admin: false));
      expect(find.byKey(const Key('circle-require-server')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, svc, FakeProcessingController.snapshot(), mode: 'off');
      expect(find.byKey(const Key('circle-require-server')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, svc, FakeProcessingController.snapshot(assist: false, serverKey: false));
      expect(find.byKey(const Key('circle-require-server')), findsNothing);
    });

    testWidgets('shown as on when the circle already requires it', (WidgetTester tester) async {
      final FakeCircleService svc = FakeCircleService();
      await pump(tester, svc, FakeProcessingController.snapshot(optOut: E2ee.optOutRequiredServer));
      final Switch sw = tester.widget<Switch>(find.descendant(of: find.byKey(const Key('circle-require-server')), matching: find.byType(Switch)));
      expect(sw.value, isTrue);
    });
  });
}
