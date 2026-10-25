import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/screens/change_password_screen.dart';
import 'package:openfamily/screens/delete_account_screen.dart';
import 'package:openfamily/screens/issue_reset_code_screen.dart';
import 'package:openfamily/screens/reset_password_screen.dart';
import 'package:openfamily/screens/security_screen.dart';
import 'package:openfamily/screens/sessions_screen.dart';
import 'package:openfamily/screens/two_factor_screen.dart';
import 'package:openfamily/services/api_client.dart';

import '../support/fake_security_api.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

Finder _field(String label) => find.widgetWithText(TextField, label);

const AccountInfo _off = AccountInfo(
    id: 'me', email: 'a@b.c', role: 'member', totpEnabled: false);
const AccountInfo _on =
    AccountInfo(id: 'me', email: 'a@b.c', role: 'admin', totpEnabled: true);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('TwoFactorScreen', () {
    testWidgets('setup, enable, then recovery codes gate on I saved them',
        (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      bool? popped;
      await tester.pumpWidget(_wrap(Builder(
        builder: (c) => TextButton(
          onPressed: () async => popped = await Navigator.of(c).push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => TwoFactorScreen(enabled: false, api: api),
            ),
          ),
          child: const Text('go'),
        ),
      )));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      await tester.enterText(_field('Password'), 'pw123456');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(api.lastArgs['password'], 'pw123456');
      expect(find.text('JBSW Y3DP EHPK 3PXP'), findsOneWidget);

      // Bad code shape is rejected locally.
      await tester.enterText(_field('6-digit code'), '12');
      await tester.tap(find.text('Turn on'));
      await tester.pump();
      expect(find.textContaining('6-digit code from your app'), findsOneWidget);
      expect(api.calls, isNot(contains('totpEnable')));

      await tester.enterText(_field('6-digit code'), '123 456');
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(api.lastArgs['code'], '123456');
      expect(find.text('AAAAA-BBBBB'), findsOneWidget);

      // Done is disabled until the box is ticked.
      FilledButton done = tester.widget(find.widgetWithText(FilledButton, 'Done'));
      expect(done.onPressed, isNull);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      done = tester.widget(find.widgetWithText(FilledButton, 'Done'));
      expect(done.onPressed, isNotNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(popped, isTrue);
    });

    testWidgets('wrong password shows the server error', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi()
        ..fail = const ApiException(400, 'password is incorrect');
      await tester.pumpWidget(
          _wrap(TwoFactorScreen(enabled: false, api: api)));
      await tester.enterText(_field('Password'), 'x');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('password is incorrect'), findsOneWidget);
    });

    testWidgets('disable sends password and code', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      await tester.pumpWidget(_wrap(TwoFactorScreen(enabled: true, api: api)));
      await tester.enterText(_field('Password'), 'pw');
      await tester.enterText(
          _field('Authenticator or recovery code'), 'AAAAA-BBBBB');
      await tester.tap(find.text('Turn off two-factor'));
      await tester.pumpAndSettle();
      expect(api.lastArgs, {'password': 'pw', 'code': 'AAAAA-BBBBB'});
    });
  });

  group('SessionsScreen', () {
    final List<SessionInfo> two = <SessionInfo>[
      SessionInfo(
        id: 'a',
        createdAt: DateTime.now(),
        lastUsedAt: DateTime.now(),
        expiresAt: null,
        userAgent: 'Dart Android',
      ),
      const SessionInfo(
        id: 'b',
        createdAt: null,
        lastUsedAt: null,
        expiresAt: null,
        userAgent: 'Firefox Linux',
      ),
    ];

    testWidgets('lists and revokes one', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi(sessions: two);
      await tester.pumpWidget(_wrap(SessionsScreen(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('Firefox on Linux'), findsOneWidget);
      await tester.tap(find.byTooltip('Sign out Firefox on Linux'));
      await tester.pumpAndSettle();
      expect(api.lastArgs['id'], 'b');
      expect(find.text('Firefox on Linux'), findsNothing);
    });

    testWidgets('offline load shows retry', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi(sessions: two)
        ..fail = const ApiException(0, 'offline');
      await tester.pumpWidget(_wrap(SessionsScreen(api: api)));
      await tester.pumpAndSettle();
      expect(find.textContaining('offline'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Firefox on Linux'), findsOneWidget);
    });

    testWidgets('log out everywhere confirms then signs out', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi(sessions: two);
      bool signedOut = false;
      await tester.pumpWidget(_wrap(SessionsScreen(
        api: api,
        onSignedOut: (_) async => signedOut = true,
      )));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Log out everywhere'));
      await tester.tap(find.text('Log out everywhere'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Log out everywhere').last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('logoutAll'));
      expect(signedOut, isTrue);
    });
  });

  group('ChangePasswordScreen', () {
    testWidgets('validates mismatch then submits with code', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      await tester.pumpWidget(
          _wrap(ChangePasswordScreen(totpEnabled: true, api: api)));
      await tester.enterText(_field('Current password'), 'old');
      await tester.enterText(_field('New password'), 'newpassword1');
      await tester.enterText(_field('Confirm new password'), 'nope');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(find.text('New passwords do not match.'), findsOneWidget);

      await tester.enterText(_field('Confirm new password'), 'newpassword1');
      await tester.enterText(
          _field('Authenticator or recovery code'), '123456');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(api.lastArgs,
          {'current': 'old', 'next': 'newpassword1', 'totp': '123456'});
    });
  });

  group('ResetPasswordScreen', () {
    testWidgets('redeems code and shows success', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      await tester.pumpWidget(_wrap(
          ResetPasswordScreen(initialEmail: 'a@b.c', api: api)));
      await tester.enterText(_field('Reset code'), 'abcde-fghjk');
      await tester.enterText(_field('New password'), 'newpassword1');
      await tester.enterText(_field('Confirm new password'), 'newpassword1');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(api.lastArgs['code'], 'ABCDE-FGHJK');
      expect(find.text('Password updated'), findsOneWidget);
    });

    testWidgets('bad code shows the generic server error', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi()
        ..fail = const ApiException(400, 'invalid or expired reset code');
      await tester.pumpWidget(_wrap(
          ResetPasswordScreen(initialEmail: 'a@b.c', api: api)));
      await tester.enterText(_field('Reset code'), 'x');
      await tester.enterText(_field('New password'), 'newpassword1');
      await tester.enterText(_field('Confirm new password'), 'newpassword1');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('invalid or expired reset code'), findsOneWidget);
    });
  });

  group('IssueResetCodeScreen', () {
    testWidgets('lists others and shows the issued code', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      await tester.pumpWidget(
          _wrap(IssueResetCodeScreen(selfId: 'me', api: api)));
      await tester.pumpAndSettle();
      expect(find.text('Me'), findsNothing);
      await tester.tap(find.text('Issue code'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Issue code'));
      await tester.pumpAndSettle();
      expect(api.lastArgs['id'], 'kid');
      expect(find.text('ABCDE-FGHJK'), findsOneWidget);
    });
  });

  group('DeleteAccountScreen', () {
    testWidgets('needs acknowledgement, step-up and confirmation',
        (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      bool deleted = false;
      await tester.pumpWidget(_wrap(DeleteAccountScreen(
        totpEnabled: true,
        api: api,
        onDeleted: (_) async => deleted = true,
      )));
      FilledButton btn =
          tester.widget(find.widgetWithText(FilledButton, 'Delete my account'));
      expect(btn.onPressed, isNull);

      await tester.enterText(_field('Password'), 'pw');
      await tester.enterText(
          _field('Authenticator or recovery code'), '123456');
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('This cannot be undone.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete my account').last);
      await tester.pumpAndSettle();
      expect(api.lastArgs, {'password': 'pw', 'totp': '123456'});
      expect(deleted, isTrue);
    });

    testWidgets('409 last-admin message is explained', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi()
        ..fail = const ApiException(409, 'cannot delete the last admin');
      await tester.pumpWidget(_wrap(DeleteAccountScreen(
          totpEnabled: false, api: api, onDeleted: (_) async {})));
      await tester.enterText(_field('Password'), 'pw');
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete my account').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Promote another admin'), findsOneWidget);
    });
  });

  group('SecurityScreen', () {
    testWidgets('shows state, admin reset entry, and exports', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi(account: _on);
      String? shared;
      await tester.pumpWidget(_wrap(SecurityScreen(
        api: api,
        shareExport: (j) async => shared = j,
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('On. Codes'), findsOneWidget);
      expect(find.text('Issue a reset code'), findsOneWidget);
      await tester.tap(find.text('Download my data'));
      await tester.pumpAndSettle();
      expect(shared, '{"complete":true}');
    });

    testWidgets('non-admin has no reset entry; load error retries',
        (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi(account: _off)
        ..fail = const ApiException(0, 'x');
      await tester.pumpWidget(_wrap(SecurityScreen(api: api)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Off. Add'), findsOneWidget);
      expect(find.text('Issue a reset code'), findsNothing);
    });

    testWidgets('large text scale does not overflow', (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi(account: _on);
      await tester.pumpWidget(MaterialApp(
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SecurityScreen(api: api),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
