import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/member_edit_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/member_edit_service.dart';
import 'package:openfamily/widgets/member_admin_section.dart';

class FakeMemberEditService implements MemberEditService {
  FakeMemberEditService({this.admin = true, this.phone, this.failWith});

  bool admin;
  String? phone;
  Object? failWith;
  final List<Map<String, String>> saved = <Map<String, String>>[];

  @override
  Future<MemberAdminView> loadAdminView(String memberId) async =>
      MemberAdminView(isAdmin: admin, phone: admin ? phone : null);

  @override
  Future<MemberEditResult> save(String memberId,
      {required String name, required String phone}) async {
    if (failWith != null) throw failWith!;
    saved.add(<String, String>{'id': memberId, 'name': name, 'phone': phone});
    return MemberEditResult(
        name: name.trim(), phone: phone.isEmpty ? null : phone);
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: child,
    );

void main() {
  group('validators', () {
    test('phone', () {
      expect(validateMemberPhone(''), isNull);
      expect(validateMemberPhone('+1 (555) 123-4567'), isNull);
      expect(validateMemberPhone('5551234567'), isNotNull);
      expect(validateMemberPhone('+0123456'), isNotNull);
      expect(validateMemberPhone('+12'), isNotNull);
    });
    test('name', () {
      expect(validateMemberName('  '), isNotNull);
      expect(validateMemberName('Ann'), isNull);
      expect(validateMemberName('x' * 101), isNotNull);
    });
  });

  group('MemberEditScreen', () {
    testWidgets('validates before calling the service', (tester) async {
      final FakeMemberEditService svc = FakeMemberEditService();
      await tester.pumpWidget(_wrap(MemberEditScreen(
          memberId: 'm1', initialName: 'Bob', service: svc)));
      await tester.enterText(find.widgetWithText(TextField, 'Name'), ' ');
      await tester.enterText(find.widgetWithText(TextField, 'Phone'), 'abc');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Name is required.'), findsOneWidget);
      expect(find.text('Use international format, e.g. +15551234567.'),
          findsOneWidget);
      expect(svc.saved, isEmpty);
    });

    testWidgets('saves and pops the result', (tester) async {
      final FakeMemberEditService svc = FakeMemberEditService();
      MemberEditResult? result;
      await tester.pumpWidget(_wrap(Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await Navigator.of(c).push(
            MaterialPageRoute<MemberEditResult>(
              builder: (_) => MemberEditScreen(
                  memberId: 'm1',
                  initialName: 'Bob',
                  initialPhone: '+15550001111',
                  service: svc),
            ),
          ),
          child: const Text('go'),
        ),
      )));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('+15550001111'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Bobby');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(svc.saved.single['name'], 'Bobby');
      expect(result?.name, 'Bobby');
    });

    testWidgets('shows the server error and stays open', (tester) async {
      final FakeMemberEditService svc = FakeMemberEditService(
          failWith: const ApiException(
              409, 'phone number already in use by another account'));
      await tester.pumpWidget(_wrap(MemberEditScreen(
          memberId: 'm1', initialName: 'Bob', service: svc)));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('phone number already in use by another account'),
          findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('offline error uses friendly copy', (tester) async {
      final FakeMemberEditService svc =
          FakeMemberEditService(failWith: const ApiException(0, 'socket'));
      await tester.pumpWidget(_wrap(MemberEditScreen(
          memberId: 'm1', initialName: 'Bob', service: svc)));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('offline'), findsOneWidget);
    });

    testWidgets('survives large text scale', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: _wrap(MemberEditScreen(
            memberId: 'm1',
            initialName: 'Bob',
            service: FakeMemberEditService())),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(48));
    });
  });

  group('MemberAdminSection', () {
    testWidgets('hidden for non-admins', (tester) async {
      await tester.pumpWidget(_wrap(Scaffold(
          body: MemberAdminSection(
              memberId: 'm1',
              memberName: 'Bob',
              service: FakeMemberEditService(admin: false, phone: '+1555')))));
      await tester.pumpAndSettle();
      expect(find.text('Phone'), findsNothing);
      expect(find.textContaining('Edit'), findsNothing);
    });

    testWidgets('admin sees phone, copies it, and can edit', (tester) async {
      String? clip;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final FakeMemberEditService svc =
          FakeMemberEditService(phone: '+15550001111');
      await tester.pumpWidget(_wrap(Scaffold(
          body: MemberAdminSection(
              memberId: 'm1', memberName: 'Bob', service: svc))));
      await tester.pumpAndSettle();
      expect(find.text('+15550001111'), findsOneWidget);
      await tester.tap(find.text('+15550001111'));
      await tester.pump();
      expect(clip, '+15550001111');
      expect(find.text('Phone number copied'), findsOneWidget);

      await tester.tap(find.text('Edit Bob'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Phone'), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(svc.saved.single['phone'], '');
      expect(find.text('Not set'), findsOneWidget);
    });
  });
}
