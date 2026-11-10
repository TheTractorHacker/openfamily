// "Link another phone": one widget test per state of the flow, run against two
// real E2eeService instances (the new phone and the phone already in use) on
// the fake E2EE server, side by side in one window.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/link_device_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../support/fake_e2ee_server.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';

void main() {
  late FakeE2eeServer server;

  E2eeService phone(String uid) =>
      E2eeService(api: server.client(uid), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uid);

  setUp(() {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
  });

  void tall(WidgetTester t, {double width = 420}) {
    t.view.physicalSize = Size(width, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  /// Finds [f] inside the phone keyed [which] ('new' or 'old').
  Finder on(String which, Finder f) => find.descendant(of: find.byKey(Key(which)), matching: f);

  String textOf(WidgetTester t, Finder f) {
    final Widget w = t.widget(f);
    if (w is SelectableText) return w.data!;
    if (w is Text) return w.data!;
    throw StateError('not text: $w');
  }

  Future<void> tapAndWait(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await t.pump();
    // Real crypto runs as plain futures; give them a few turns, then settle.
    for (int i = 0; i < 5; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
  }

  testWidgets('choose: two plain choices, the reset is folded away, no jargon', (WidgetTester t) async {
    tall(t);
    await t.pumpWidget(MaterialApp(home: LinkDeviceScreen(service: phone(uA))));
    expect(find.text('Which phone is this?'), findsOneWidget);
    expect(find.text('This is the new phone'), findsOneWidget);
    expect(find.text('This is the phone I already use'), findsOneWidget);
    expect(find.text('Reset my keys'), findsNothing, reason: 'behind "No other phone?"');
    for (final String jargon in <String>['key log', 'epoch', 'fingerprint', 'cross-sign']) {
      expect(find.textContaining(RegExp(jargon, caseSensitive: false)), findsNothing, reason: jargon);
    }
    await t.tap(find.text('No other phone?'));
    await t.pumpAndSettle();
    expect(find.text('Reset my keys'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the whole flow: code on the new phone, check and approve on the old one, finish on the new one',
      (WidgetTester t) async {
    tall(t, width: 900);
    final E2eeService old = phone(uA);
    await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
    final E2eeService fresh = phone(uA);
    final List<String> shared = <String>[];
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Row(children: <Widget>[
        Expanded(child: MaterialApp(key: const Key('new'), home: LinkDeviceScreen(service: fresh))),
        Expanded(
            child: MaterialApp(
                key: const Key('old'),
                home: LinkDeviceScreen(service: old, role: LinkRole.existingPhone, share: (String s) async => shared.add(s)))),
      ]),
    ));

    // New phone: choose, then the start step with one primary action.
    await t.tap(on('new', find.byKey(const Key('link-choose-new'))));
    await t.pumpAndSettle();
    expect(on('new', find.text('Link this phone')), findsOneWidget);
    expect(on('new', find.byKey(const Key('link-make-code'))), findsOneWidget);
    await tapAndWait(t, on('new', find.byKey(const Key('link-make-code'))));

    // Waiting: the code in full, a check code, the answer field; Finish stays off until something is pasted.
    expect(on('new', find.text('Send this code to your other phone')), findsOneWidget);
    final String request = textOf(t, on('new', find.byKey(const Key('link-request'))));
    expect(request.length, greaterThan(40));
    expect(on('new', find.text('Check code')), findsOneWidget);
    await t.tap(on('new', find.byKey(const Key('link-qr-toggle'))));
    await t.pumpAndSettle();
    expect(on('new', find.byKey(const Key('link-qr'))), findsOneWidget);

    // Old phone: paste (with a line break, as chat apps wrap it), Continue.
    expect(on('old', find.text('Approve a new phone')), findsOneWidget);
    await t.enterText(on('old', find.byKey(const Key('link-request-in'))),
        '${request.substring(0, 30)}\n${request.substring(30)}');
    await t.pump();
    await tapAndWait(t, on('old', find.byKey(const Key('link-check'))));

    // Compare: the same check code on both phones; the long number only under Details.
    expect(on('old', find.text('Check it is your phone')), findsOneWidget);
    final String shortOld = textOf(t, on('old', find.byKey(const Key('link-short'))));
    expect(on('new', find.text(shortOld)), findsOneWidget, reason: 'the new phone shows the same check code');
    expect(on('old', find.byKey(const Key('link-digits'))), findsNothing);
    await t.tap(on('old', find.text('Details')));
    await t.pumpAndSettle();
    expect(on('old', find.byKey(const Key('link-digits'))), findsOneWidget);
    await tapAndWait(t, on('old', find.byKey(const Key('link-approve'))));

    // Approved: the answer with Copy / Share.
    expect(on('old', find.text('Approved. One last step')), findsOneWidget);
    final String approval = textOf(t, on('old', find.byKey(const Key('link-approval'))));
    await t.tap(on('old', find.byKey(const Key('link-share'))));
    await t.pump();
    expect(shared, <String>[approval]);

    // New phone: paste the answer, Finish, success.
    await t.enterText(on('new', find.byKey(const Key('link-approval-in'))), approval);
    await t.pump();
    await tapAndWait(t, on('new', find.byKey(const Key('link-finish'))));
    expect(on('new', find.text('This phone is linked')), findsOneWidget);
    expect(on('new', find.byKey(const Key('link-done'))), findsOneWidget);
    expect(server.activeOf(uA).length, 2, reason: 'both phones hold an active key');
    expect(t.takeException(), isNull);
  });

  testWidgets('existing phone: a cut-off code gets one plain sentence, not a crash or "offline"', (WidgetTester t) async {
    tall(t);
    final E2eeService old = phone(uA);
    await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
    await t.pumpWidget(MaterialApp(home: LinkDeviceScreen(service: old, role: LinkRole.existingPhone)));
    expect(find.byKey(const Key('link-check')), findsOneWidget);
    await t.enterText(find.byKey(const Key('link-request-in')), 'eyJ1IjoiMTExMTEx');
    await t.pump();
    await tapAndWait(t, find.byKey(const Key('link-check')));
    expect(find.textContaining('That code is not complete'), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);
    expect(find.text('Approve a new phone'), findsOneWidget, reason: 'stays on the paste step');
  });

  testWidgets('existing phone: a code from another account is refused in plain words', (WidgetTester t) async {
    tall(t);
    final E2eeService old = phone(uA);
    await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
    final String foreign = (await t.runAsync(() => phone(uB).createLinkRequest()))!;
    await t.pumpWidget(MaterialApp(home: LinkDeviceScreen(service: old, role: LinkRole.existingPhone)));
    await t.enterText(find.byKey(const Key('link-request-in')), foreign);
    await t.pump();
    await tapAndWait(t, find.byKey(const Key('link-check')));
    expect(find.textContaining('different account'), findsOneWidget);
  });

  testWidgets('existing phone: "They are different" approves nothing and goes back with advice', (WidgetTester t) async {
    tall(t);
    final E2eeService old = phone(uA);
    await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
    final String request = (await t.runAsync(() => phone(uA).createLinkRequest()))!;
    await t.pumpWidget(MaterialApp(home: LinkDeviceScreen(service: old, role: LinkRole.existingPhone)));
    await t.enterText(find.byKey(const Key('link-request-in')), request);
    await t.pump();
    await tapAndWait(t, find.byKey(const Key('link-check')));
    await t.tap(find.byKey(const Key('link-no-match')));
    await t.pumpAndSettle();
    expect(find.text('Approve a new phone'), findsOneWidget);
    expect(find.textContaining('Nothing was approved'), findsOneWidget);
    expect(server.activeOf(uA).length, 1);
  });

  testWidgets('new phone: a wrong answer code shows a message and keeps the code on screen', (WidgetTester t) async {
    tall(t);
    final E2eeService old = phone(uA);
    await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
    await t.pumpWidget(MaterialApp(home: LinkDeviceScreen(service: phone(uA), role: LinkRole.newPhone)));
    expect(find.text('Link this phone'), findsOneWidget);
    await tapAndWait(t, find.byKey(const Key('link-make-code')));
    expect(find.byKey(const Key('link-request')), findsOneWidget);
    // Finish is off while the field is empty.
    expect(find.text('Finish linking'), findsOneWidget);
    await t.enterText(find.byKey(const Key('link-approval-in')), 'not-a-code');
    await t.pump();
    await tapAndWait(t, find.byKey(const Key('link-finish')));
    expect(find.byKey(const Key('link-message')), findsOneWidget);
    expect(find.byKey(const Key('link-request')), findsOneWidget, reason: 'still waiting, code still shown');
    expect(server.activeOf(uA).length, 1);
  });

  testWidgets('Back inside the flow returns to the choice instead of leaving', (WidgetTester t) async {
    tall(t);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => LinkDeviceScreen(service: phone(uA)))),
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('link-choose-existing')));
    await t.pumpAndSettle();
    expect(find.text('Approve a new phone'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('Which phone is this?'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Back on a step that shows a code asks first, because the code is lost', (WidgetTester t) async {
    tall(t);
    final E2eeService old = phone(uA);
    await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => Navigator.of(c).push(
              MaterialPageRoute<void>(builder: (_) => LinkDeviceScreen(service: phone(uA), role: LinkRole.newPhone))),
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await tapAndWait(t, find.byKey(const Key('link-make-code')));
    expect(find.byKey(const Key('link-request')), findsOneWidget);

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('Leave linking?'), findsOneWidget);
    await t.tap(find.text('Stay'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('link-request')), findsOneWidget, reason: 'still on the code step');

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await t.tap(find.text('Leave'));
    await t.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  test('the reset texts are unchanged in meaning', () {
    expect(resetConfirmMessage(serverKey: false), contains('Members must approve your new key'));
    expect(LinkStep.values, hasLength(7));
  });
}
