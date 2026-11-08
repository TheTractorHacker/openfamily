import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/app_compat.dart';
import 'package:openfamily/services/attention_service.dart';
import 'package:openfamily/services/delivery_status.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart' show ServerJoinInfo;
import 'package:openfamily/services/offline/server_reachability.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/attention_center.dart';
import 'package:openfamily/widgets/location_tab_view.dart';
import 'package:openfamily/widgets/server_prompts.dart';
import 'package:openfamily/widgets/sync_status_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/location_fixtures.dart';

class _Actions extends AttentionActions {
  _Actions(this.log);
  final List<String> log;

  @override
  Future<void> tryAgain() async => log.add('try');
  @override
  void signIn() => log.add('signin');
  @override
  Future<void> openDelivery(AttentionContext c, Circle circle) async => log.add('delivery:${circle.id}');
  @override
  Future<void> openEncryptionKeys(AttentionContext c) async => log.add('keys');
  @override
  Future<void> openDiagnostics(AttentionContext c) async => log.add('diagnostics');
  @override
  Future<bool> useServer(AttentionContext c, Circle circle) async {
    log.add('use:${circle.id}');
    return true;
  }

  @override
  Future<void> showUpdateHelp(AttentionContext c) async => log.add('update-help');
  @override
  Future<void> dismissAutoNotice(String circleId) async => log.add('auto-ok:$circleId');
  @override
  Future<void> keepOnPhone(String circleId) async => log.add('keep:$circleId');
  @override
  Future<void> approveServerJoin() async => log.add('approve');
}

const Circle _private = Circle(
  id: 'a',
  name: 'Foley Family',
  role: 'member',
  sharingEnabled: true,
  memberCount: 4,
  isPrimary: true,
  e2eeMode: 'private',
  serverAssist: true,
);

void _report(Circle c, {String summary = 'ok'}) {
  DeliveryHints.circleById[c.id] = c;
  DeliveryHints.put(CircleDelivery(
    circleId: c.id,
    summary: summary,
    members: const <MemberDelivery>[MemberDelivery(userId: 'me', name: 'Me', you: true, reason: DeliveryReason.ok)],
    at: DateTime.now(),
  ));
}

void main() {
  late ServerReachability r;
  late AttentionService svc;
  late List<String> log;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppCompat.debugReset();
    DeliveryHints.clear();
    ServerChoiceStore.debugReset();
    r = ServerReachability(probe: () async => true);
    svc = AttentionService(reachability: r);
    log = <String>[];
  });

  tearDown(() {
    svc.dispose();
    r.dispose();
    AppCompat.debugReset();
    DeliveryHints.clear();
  });

  Future<void> pumpBar(WidgetTester t) => t.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          appBar: AppBar(title: const Text('Safety'), actions: <Widget>[AttentionButton(service: svc, actions: _Actions(log))]),
          body: const SizedBox.expand(),
        ),
      ));

  Color iconColor(WidgetTester t) => t
      .widget<Icon>(find.descendant(of: find.byKey(const Key('attention-button')), matching: find.byType(Icon)).first)
      .color!;

  Future<void> openSheet(WidgetTester t) async {
    await t.tap(find.byKey(const Key('attention-button')));
    await t.pumpAndSettle();
    expect(find.text('Needs your attention'), findsOneWidget);
  }

  testWidgets('hidden when nothing needs attention', (WidgetTester t) async {
    await pumpBar(t);
    expect(find.byKey(const Key('attention-button')), findsNothing);
  });

  testWidgets('count badge, amber for a choice, red once something is broken; semantic label and 48dp', (WidgetTester t) async {
    await pumpBar(t);
    AppCompat.state.value = const CompatState(status: CompatStatus.recommended);
    _report(_private);
    await t.pump();
    expect(find.byKey(const Key('attention-button')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('attention-button')), matching: find.text('2')), findsOneWidget);
    expect(iconColor(t), const Color(0xFFB45309));
    expect(find.bySemanticsLabel('2 things need your attention'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('attention-button'))).height, greaterThanOrEqualTo(48));

    r.state.value = SyncState.unreachable;
    await t.pump();
    expect(find.descendant(of: find.byKey(const Key('attention-button')), matching: find.text('3')), findsOneWidget);
    expect(iconColor(t), const Color(0xFFC62828));
  });

  testWidgets('the sheet has one card per item with title, reason and one primary action', (WidgetTester t) async {
    await pumpBar(t);
    _report(_private, summary: 'nobody_sending');
    r.state.value = SyncState.unreachable;
    await t.pump();
    await openSheet(t);
    expect(find.text("Can't reach your server."), findsOneWidget);
    expect(find.text('Nobody has sent an update in Foley Family.'), findsOneWidget);
    expect(find.text('Use the server for Foley Family?'), findsOneWidget);
    expect(find.byKey(const Key('attention-primary-offline')), findsOneWidget);
    expect(find.byKey(const Key('attention-secondary-offline')), findsNothing);
  });

  testWidgets('actions: Try again, Fix it, Not now', (WidgetTester t) async {
    await pumpBar(t);
    _report(_private, summary: 'nobody_sending');
    r.state.value = SyncState.unreachable;
    AppCompat.state.value = const CompatState(status: CompatStatus.recommended);
    await t.pump();
    await openSheet(t);

    await t.tap(find.byKey(const Key('attention-primary-offline')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attention-primary-nobody:a')));
    await t.pumpAndSettle();
    expect(log, <String>['try', 'delivery:a']);

    await t.ensureVisible(find.byKey(const Key('attention-secondary-update-available')));
    await t.tap(find.byKey(const Key('attention-secondary-update-available')));
    await t.pumpAndSettle();
    expect(AppCompat.dismissed.value, isTrue, reason: 'the existing session dismissal');
    expect(find.text('A newer Orbitly is available.'), findsNothing);

    await t.tap(find.byKey(const Key('attention-secondary-nobody:a')));
    await t.pumpAndSettle();
    expect(find.text('Nobody has sent an update in Foley Family.'), findsNothing);
  });

  testWidgets('"Keep on my phone" is remembered by ServerChoiceStore', (WidgetTester t) async {
    await pumpBar(t);
    _report(_private);
    await t.pump();
    await openSheet(t);
    await t.tap(find.byKey(const Key('attention-secondary-server-choice:a')));
    await t.pumpAndSettle();
    expect(ServerChoiceStore.answered('a'), isTrue);
    expect((await SharedPreferences.getInstance()).getBool('server_choice_answered_a'), isTrue);
    expect(find.byKey(const Key('attention-empty')), findsOneWidget);
  });

  testWidgets('re-keyed phone: one tap "Use the server again" runs the add-server flow and is remembered', (WidgetTester t) async {
    await pumpBar(t);
    _report(_private);
    await ServerChoiceStore.markAnswered('a');
    svc.debugSet(choiceLost: <String, ServerChoiceLost>{'a': (oldDeviceId: 'old', recommended: true)});
    await t.pump();
    await openSheet(t);
    expect(find.text('Use the server again for Foley Family?'), findsOneWidget);
    await t.tap(find.byKey(const Key('attention-info-server-again:a')));
    await t.pump();
    expect(find.textContaining('recommends the server'), findsOneWidget);
    await t.tap(find.byKey(const Key('attention-primary-server-again:a')));
    await t.pumpAndSettle();
    expect(log, <String>['use:a']);
    expect(ServerChoiceStore.reofferAnswered('a', 'old'), isTrue);
    expect(find.text('Use the server again for Foley Family?'), findsNothing);
  });

  testWidgets('server join approve and auto-apply OK / Keep on my phone', (WidgetTester t) async {
    await pumpBar(t);
    svc.debugSet(
      join: const ServerJoinInfo(builtin: true, waiting: true, canApprove: true, short: 'AB-12'),
      autoNotices: const <AutoNotice>[AutoNotice('a', 'Foley Family'), AutoNotice('b', 'Grandparents')],
    );
    await t.pump();
    await openSheet(t);
    expect(find.textContaining('AB-12'), findsOneWidget);
    await t.tap(find.byKey(const Key('attention-primary-server-join')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attention-primary-auto:a')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attention-secondary-auto:b')));
    await t.pumpAndSettle();
    expect(log, <String>['approve', 'auto-ok:a', 'keep:b']);
    expect(find.byKey(const Key('attention-empty')), findsOneWidget);
  });

  testWidgets('update and sign-in actions', (WidgetTester t) async {
    await pumpBar(t);
    AppCompat.state.value = const CompatState(status: CompatStatus.required);
    r.state.value = SyncState.signedOut;
    await t.pump();
    await openSheet(t);
    await t.tap(find.byKey(const Key('attention-primary-update-required')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attention-primary-signed-out')));
    await t.pumpAndSettle();
    expect(log, <String>['update-help', 'signin']);
    expect(find.text('Needs your attention'), findsNothing, reason: 'sign-in closes the sheet');
  });

  group('360x640 at 200% text', () {
    void small(WidgetTester t) {
      t.view.physicalSize = const Size(360, 640);
      t.view.devicePixelRatio = 1;
      t.view.padding = const FakeViewPadding(top: 24);
      addTearDown(t.view.reset);
    }

    testWidgets('the sheet with every kind of card does not overflow', (WidgetTester t) async {
      small(t);
      AppCompat.state.value = const CompatState(status: CompatStatus.required);
      _report(_private, summary: 'nobody_sending');
      r.lastOkAt = DateTime(2026, 11, 8, 9, 2);
      r.state.value = SyncState.unreachable;
      svc.debugSet(
        join: const ServerJoinInfo(builtin: true, waiting: true, canApprove: true, short: 'AB-12'),
        autoNotices: const <AutoNotice>[AutoNotice('b', 'Grandparents')],
      );
      await t.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(2), padding: EdgeInsets.only(top: 24)),
          child: Scaffold(
            appBar: AppBar(actions: <Widget>[AttentionButton(service: svc, actions: _Actions(log))]),
            body: const SizedBox.expand(),
          ),
        ),
      ));
      await openSheet(t);
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.byKey(const Key('attention-primary-auto:b')), 200, scrollable: find.byType(Scrollable).last);
      expect(t.takeException(), isNull);
    });

    testWidgets('map top row: switcher, chip, offline pill and the icon never overlap; nothing pushes the map down', (WidgetTester t) async {
      small(t);
      final AttentionService app = AttentionService.instance;
      addTearDown(() {
        ServerReachability.instance.state.value = SyncState.upToDate;
        ServerReachability.instance.lastOkAt = null;
        AppCompat.debugReset();
        app.debugReset();
      });
      AppCompat.state.value = const CompatState(status: CompatStatus.recommended);
      ServerReachability.instance.lastOkAt = DateTime(2026, 11, 8, 9, 2);
      ServerReachability.instance.state.value = SyncState.unreachable;
      await t.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(2), padding: EdgeInsets.only(top: 24)),
          child: LocationTabView(
            map: const FakeMap(),
            circleName: 'Foley Family',
            circles: const <Circle>[_private],
            members: const <Member>[kSelf],
            selfId: 'me',
            sharingPaused: false,
            loading: false,
            hasFamily: true,
            locationOff: false,
            placesLoader: fakePlaces,
            onCheckIn: () {},
            onSos: () {},
            onOpenSettings: () {},
            onInvite: () {},
            onToggleSatellite: () {},
            onLocate: () {},
            onSelectMember: (_) {},
            onRetry: () {},
            onEnableLocation: () {},
            topOverlay: const SyncStatusChip(),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final Finder button = find.byKey(const Key('attention-button'));
      final Finder chip = find.byKey(const ValueKey<String>('private-circle-badge'));
      final Finder pill = find.byKey(const Key('sync-status-chip'));
      final Finder circlePill = find.bySemanticsLabel(RegExp('^Circle: Foley Family'));
      for (final Finder f in <Finder>[button, chip, pill, circlePill]) {
        expect(f, findsOneWidget);
      }
      expect(find.text('Private + server'), findsOneWidget);
      final Rect b = t.getRect(button), c = t.getRect(chip), p = t.getRect(pill), s = t.getRect(circlePill);
      for (final (Rect, Rect) pair in <(Rect, Rect)>[(b, c), (b, p), (b, s), (c, p), (c, s), (p, s)]) {
        expect(pair.$1.overlaps(pair.$2), isFalse, reason: '$pair');
      }
      expect(s.top, greaterThanOrEqualTo(24), reason: 'the top row keeps clear of the status bar');
      expect(t.getRect(find.byType(FakeMap)).top, 0, reason: 'nothing pushes the map down');
    });
  });
}
