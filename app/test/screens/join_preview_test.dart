import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/join_circle_screen.dart';
import 'package:openfamily/services/join_service.dart';

Future<void> pumpJoin(WidgetTester t, Future<InvitePreview?> Function(String) loader, {String code = 'AB12CD34'}) async {
  t.view.physicalSize = const Size(390, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(home: JoinCircleScreen(initialCode: code, previewLoader: loader)));
  await t.pumpAndSettle();
}

String note(WidgetTester t) => t.widget<Text>(find.descendant(of: find.byKey(const Key('join-processing-note')), matching: find.byType(Text))).data!;

void main() {
  testWidgets('assistance on, members choose: says so and names the suggestion without opting anyone in', (t) async {
    await pumpJoin(t, (_) async => const InvitePreview(isPrivate: true, serverAssist: true, required: false, defaultServer: true));
    expect(note(t), contains('Server processing: on, you choose'));
    expect(note(t), contains('"Server processing" is suggested'));
    expect(note(t), contains('unless you confirm it'));
  });

  testWidgets('required: the disclosure says consent is needed to take part', (t) async {
    await pumpJoin(t, (_) async => const InvitePreview(isPrivate: true, serverAssist: true, required: true, defaultServer: false));
    expect(note(t), contains('Server processing: required'));
    expect(note(t), contains('your own consent'));
  });

  testWidgets('private without assistance and a normal circle', (t) async {
    await pumpJoin(t, (_) async => const InvitePreview(isPrivate: true, serverAssist: false, required: false, defaultServer: false));
    expect(note(t), contains('Server processing: off'));
    await t.pumpWidget(const SizedBox());
    await pumpJoin(t, (_) async => const InvitePreview(isPrivate: false, serverAssist: false, required: false, defaultServer: false));
    expect(note(t), contains('normal circle'));
  });

  testWidgets('no preview (404, offline, old server) keeps the generic note', (t) async {
    await pumpJoin(t, (_) async => null);
    expect(note(t), contains('If the circle is a Private circle'));
    await t.pumpWidget(const SizedBox());
    await pumpJoin(t, (_) async => throw Exception('offline'));
    expect(note(t), contains('If the circle is a Private circle'));
  });

  testWidgets('typing a code asks for a preview after a pause', (t) async {
    final List<String> asked = <String>[];
    await pumpJoin(t, (String c) async {
      asked.add(c);
      return null;
    }, code: '');
    expect(asked, isEmpty);
    await t.enterText(find.byType(TextField), 'ZZ99YY88');
    await t.pump(const Duration(milliseconds: 600));
    await t.pumpAndSettle();
    expect(asked, <String>['ZZ99YY88']);
  });

  testWidgets('a legacy circle is described as the old mode, not as private and safe', (t) async {
    await pumpJoin(t, (_) async => const InvitePreview(isPrivate: true, serverAssist: false, required: false, defaultServer: false, legacy: true));
    expect(note(t), contains('OLD trusted-server mode'));
    expect(note(t), isNot(contains('cannot read your location')));
  });

  test('InvitePreview reads the legacy flag and tolerates its absence', () {
    final Map<String, dynamic> base = <String, dynamic>{'private': true, 'server_assist': false, 'member_opt_out': 'allowed', 'default_for_new': 'phone'};
    expect(InvitePreview.tryParse(base)!.legacy, isFalse);
    expect(InvitePreview.tryParse(<String, dynamic>{...base, 'legacy': true})!.legacy, isTrue);
  });

  test('InvitePreview.tryParse accepts only the exact shape', () {
    final InvitePreview? p = InvitePreview.tryParse(<String, dynamic>{'private': true, 'server_assist': true, 'member_opt_out': 'required_server', 'default_for_new': 'phone'});
    expect((p!.isPrivate, p.serverAssist, p.required, p.defaultServer), (true, true, true, false));
    expect(InvitePreview.tryParse(<String, dynamic>{'private': true, 'server_assist': true, 'member_opt_out': 'x', 'default_for_new': 'phone'}), isNull);
    expect(InvitePreview.tryParse(<String, dynamic>{'private': 'yes'}), isNull);
    expect(InvitePreview.tryParse('nope'), isNull);
  });
}
