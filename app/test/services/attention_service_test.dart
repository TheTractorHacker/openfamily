import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/app_compat.dart';
import 'package:openfamily/services/attention_service.dart';
import 'package:openfamily/services/delivery_status.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart' show ServerJoinInfo;
import 'package:openfamily/services/offline/server_reachability.dart';
import 'package:openfamily/widgets/server_prompts.dart';
import 'package:shared_preferences/shared_preferences.dart';

Circle circle(String id, {bool admin = false, bool assist = true, bool myServer = false, String mode = 'private'}) => Circle(
      id: id,
      name: 'Circle $id',
      role: admin ? 'admin' : 'member',
      sharingEnabled: true,
      memberCount: 3,
      e2eeMode: mode,
      serverAssist: assist,
      myLaneServer: myServer,
    );

void report(Circle c, {String summary = 'ok', DeliveryReason me = DeliveryReason.ok, List<MemberDelivery> others = const <MemberDelivery>[]}) {
  DeliveryHints.circleById[c.id] = c;
  DeliveryHints.put(CircleDelivery(
    circleId: c.id,
    summary: summary,
    members: <MemberDelivery>[MemberDelivery(userId: 'me', name: 'Me', you: true, reason: me), ...others],
    at: DateTime.now(),
  ));
}

void main() {
  late ServerReachability r;
  late AttentionService s;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppCompat.debugReset();
    DeliveryHints.clear();
    ServerChoiceStore.debugReset();
    r = ServerReachability(probe: () async => true);
    s = AttentionService(reachability: r);
  });

  tearDown(() {
    s.dispose();
    r.dispose();
    AppCompat.debugReset();
    DeliveryHints.clear();
  });

  List<AttentionKind> kinds() => s.value.map((AttentionItem i) => i.kind).toList();

  test('nothing needs attention: no items, no severity (the icon is hidden)', () {
    expect(s.value, isEmpty);
    expect(s.count, 0);
    expect(s.worst, isNull);
  });

  group('app updates (AppCompat)', () {
    test('required is red and has no "Not now"', () {
      AppCompat.state.value = const CompatState(status: CompatStatus.required);
      expect(kinds(), <AttentionKind>[AttentionKind.updateRequired]);
      expect(s.worst, AttentionSeverity.critical);
      expect(s.value.single.secondary, isNull);
    });

    test('circles needing a newer app name the circles', () {
      AppCompat.noteCircles(<bool>[true, false], names: <String>['Foley Family']);
      expect(kinds(), <AttentionKind>[AttentionKind.circleUpdate]);
      expect(s.value.single.title, contains('Foley Family'));
      expect(s.worst, AttentionSeverity.warning);
    });

    test('recommended is amber and the existing session dismissal hides it', () {
      AppCompat.state.value = const CompatState(status: CompatStatus.recommended, latest: '0.27.0');
      expect(kinds(), <AttentionKind>[AttentionKind.updateAvailable]);
      expect(s.value.single.title, contains('0.27.0'));
      expect(s.value.single.secondary, 'Not now');
      AppCompat.dismissed.value = true;
      expect(s.value, isEmpty);
    });
  });

  group('connection (the state behind the offline pill)', () {
    test('unreachable is red, offers Try again and says when it last synced', () {
      r.lastOkAt = DateTime(2026, 11, 8, 9, 2);
      r.setPending(2);
      r.state.value = SyncState.unreachable;
      expect(kinds(), <AttentionKind>[AttentionKind.offline]);
      expect(s.worst, AttentionSeverity.critical);
      expect(s.value.single.action, 'Try again');
      expect(s.value.single.why, contains('last synced'));
      expect(s.value.single.why, contains('2 updates'));
      r.state.value = SyncState.upToDate;
      expect(s.value, isEmpty);
    });

    test('signed out asks to sign in', () {
      r.state.value = SyncState.signedOut;
      expect(kinds(), <AttentionKind>[AttentionKind.signedOut]);
      expect(s.value.single.action, 'Sign in');
    });
  });

  group('delivery (DeliveryHints)', () {
    test('nobody sending in a Private circle: reason + Fix it; Not now snoozes', () {
      final Circle c = circle('a', assist: false);
      report(c, summary: 'nobody_sending', others: <MemberDelivery>[
        const MemberDelivery(userId: 'u2', name: 'Anna Foley', you: false, reason: DeliveryReason.neverSent),
      ]);
      expect(kinds(), <AttentionKind>[AttentionKind.nobodySending]);
      final AttentionItem it = s.value.single;
      expect(it.title, 'Nobody has sent an update in Circle a.');
      expect(it.why, contains("Anna hasn't sent"));
      expect(it.action, 'Fix it');
      s.snooze(it);
      expect(s.value, isEmpty);
    });

    test("this phone's key waiting for approval points to Encryption keys and holds back the server question", () {
      final Circle c = circle('a');
      report(c, me: DeliveryReason.notApproved);
      expect(kinds(), <AttentionKind>[AttentionKind.keyWaiting]);
      expect(s.value.single.action, 'Open Encryption keys');
    });
  });

  group('server questions (ServerPrompts rules)', () {
    test('member: "Use the server?" until "Keep on my phone" is remembered', () async {
      report(circle('a'));
      expect(kinds(), <AttentionKind>[AttentionKind.serverChoice]);
      expect(s.value.single.secondary, 'Keep on my phone');
      await ServerChoiceStore.markAnswered('a');
      expect(s.value, isEmpty);
    });

    test('already on the server: nothing to ask', () {
      report(circle('a', myServer: true));
      expect(s.value, isEmpty);
    });

    test('re-keyed phone: "Use the server again?" even though the first question was answered', () async {
      report(circle('a'));
      await ServerChoiceStore.markAnswered('a');
      expect(s.value, isEmpty);
      s.debugSet(choiceLost: <String, ServerChoiceLost>{'a': (oldDeviceId: 'old-dev', recommended: true)});
      expect(kinds(), <AttentionKind>[AttentionKind.serverChoiceAgain]);
      final AttentionItem it = s.value.single;
      expect(it.title, 'Use the server again for Circle a?');
      expect(it.action, 'Use the server again');
      expect(it.info, contains('recommends the server'));
      expect(it.data, 'old-dev');
      await ServerChoiceStore.markReofferAnswered('a', 'old-dev');
      expect(s.value, isEmpty);
      // A later reset (another revoked key) asks again.
      s.debugSet(choiceLost: <String, ServerChoiceLost>{'a': (oldDeviceId: 'newer-dev', recommended: true)});
      expect(kinds(), <AttentionKind>[AttentionKind.serverChoiceAgain]);
    });

    test('re-keyed phone still waiting for approval: approve first, no server question yet', () {
      report(circle('a'), me: DeliveryReason.notApproved);
      s.debugSet(choiceLost: <String, ServerChoiceLost>{'a': (oldDeviceId: 'old', recommended: true)});
      expect(kinds(), <AttentionKind>[AttentionKind.keyWaiting]);
    });

    test('admin setup is neutral and snoozes for the session', () {
      report(circle('a', admin: true, assist: false));
      expect(kinds(), <AttentionKind>[AttentionKind.serverAdminSetup]);
      expect(s.worst, AttentionSeverity.info);
      ServerChoiceStore.snooze('a');
      expect(s.value, isEmpty);
    });

    test('auto-apply notice and server join come from their loaders', () {
      s.debugSet(
        autoNotices: const <AutoNotice>[AutoNotice('a', 'Foley Family')],
        join: const ServerJoinInfo(builtin: true, waiting: true, canApprove: true, short: '12-34'),
      );
      expect(kinds(), containsAll(<AttentionKind>[AttentionKind.serverAutoApplied, AttentionKind.serverJoin]));
      final AttentionItem join = s.value.firstWhere((AttentionItem i) => i.kind == AttentionKind.serverJoin);
      expect(join.why, contains('12-34'));
      s.snooze(join);
      expect(kinds(), <AttentionKind>[AttentionKind.serverAutoApplied]);
      s.autoNoticeDone('a');
      expect(s.value, isEmpty);
    });

    test('a server join this phone cannot approve is not shown', () {
      s.debugSet(join: const ServerJoinInfo(builtin: true, waiting: true, canApprove: false));
      expect(s.value, isEmpty);
    });
  });

  group('diagnostics problems list', () {
    test('reuses evaluateDiagnostics: location and key failures only', () {
      final List<DiagCheck> checks = evaluateDiagnostics(DiagFacts(
        now: DateTime.utc(2026, 11, 8),
        locationService: false,
        locationPermission: 'always',
        hasPrivateCircle: true,
        vaultReadable: false,
        vaultDetail: 'unreadable',
      ));
      s.debugSet(diagnostics: checks);
      expect(kinds(), containsAll(<AttentionKind>[AttentionKind.phoneProblem, AttentionKind.keyUnreadable]));
      expect(s.value.where((AttentionItem i) => i.kind == AttentionKind.phoneProblem).map((AttentionItem i) => i.id), <String>['diag:location_service']);
      expect(s.worst, AttentionSeverity.critical);
    });

    test('passing checks and checks outside the list add nothing', () {
      s.debugSet(diagnostics: const <DiagCheck>[
        DiagCheck(id: 'location_service', title: 't', status: DiagStatus.pass, detail: 'd'),
        DiagCheck(id: 'push', title: 't', status: DiagStatus.fail, detail: 'd'),
      ]);
      expect(s.value, isEmpty);
    });
  });

  test('worst first, badge count is the number of items, listeners hear changes', () {
    int heard = 0;
    s.addListener(() => heard++);
    report(circle('a', assist: false), summary: 'nobody_sending');
    AppCompat.state.value = const CompatState(status: CompatStatus.recommended);
    r.state.value = SyncState.unreachable;
    expect(s.count, 3);
    expect(s.value.first.kind, AttentionKind.offline);
    expect(s.value.first.severity, AttentionSeverity.critical);
    expect(heard, greaterThanOrEqualTo(3));
  });
}
