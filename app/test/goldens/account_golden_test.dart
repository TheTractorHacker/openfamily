import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/screens/add_locations_screen.dart';
import 'package:openfamily/screens/change_password_screen.dart';
import 'package:openfamily/screens/circle_create_screen.dart';
import 'package:openfamily/screens/delete_account_screen.dart';
import 'package:openfamily/screens/issue_reset_code_screen.dart';
import 'package:openfamily/screens/member_edit_screen.dart';
import 'package:openfamily/screens/member_profile_screen.dart';
import 'package:openfamily/screens/people_screen.dart';
import 'package:openfamily/screens/privacy_policy_screen.dart';
import 'package:openfamily/screens/server_config_screen.dart';
import 'package:openfamily/screens/sessions_screen.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/screens/two_factor_screen.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_security_api.dart';
import '../screens/circles_screens_test.dart' show FakeCircleService;

/// Golden renders of the account / people / settings screens. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens`.
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
        // Explicit list-tile styles carry no family; keep the golden font.
        listTileTheme: theme.listTileTheme.copyWith(
          titleTextStyle:
              theme.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
          subtitleTextStyle: theme.listTileTheme.subtitleTextStyle
              ?.copyWith(fontFamily: 'Roboto'),
        ),
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
}) {
  for (final bool dark in <bool>[false, true]) {
    final String file = '${name}_${dark ? 'dark' : 'light'}'
        '${scale == 1 ? '' : '_x${scale.toStringAsFixed(0)}'}';
    testWidgets('golden $file', (WidgetTester t) async {
      t.view.physicalSize = const Size(780, 1688);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
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


const Member _frank = Member(
  id: 'frank',
  name: 'Frank',
  position: null,
  status: MemberStatus.normal,
  batteryPercent: 82,
  address: '12 Oak Street',
);
const Member _june = Member(
  id: 'june',
  name: 'June',
  position: null,
  status: MemberStatus.stopped,
  batteryPercent: 0,
  address: 'Work',
);

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ServerConfig.instance.debugReset();
  });

  _golden('acct_change_password',
      () => ChangePasswordScreen(totpEnabled: true, api: FakeSecurityApi()));
  _golden('acct_change_password',
      () => ChangePasswordScreen(totpEnabled: true, api: FakeSecurityApi()),
      scale: 2);
  _golden(
      'acct_delete',
      () => DeleteAccountScreen(
          totpEnabled: false, api: FakeSecurityApi(), onDeleted: (_) async {}));
  _golden(
      'acct_delete',
      () => DeleteAccountScreen(
          totpEnabled: false, api: FakeSecurityApi(), onDeleted: (_) async {}),
      scale: 2);
  _golden(
      'acct_sessions',
      () => SessionsScreen(
            api: FakeSecurityApi(sessions: <SessionInfo>[
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
            ]),
          ));
  _golden(
      'acct_sessions',
      () => SessionsScreen(
            api: FakeSecurityApi(sessions: <SessionInfo>[
              const SessionInfo(
                id: 'b',
                createdAt: null,
                lastUsedAt: null,
                expiresAt: null,
                userAgent: 'Firefox Linux',
              ),
            ]),
          ),
      scale: 2);
  _golden('acct_two_factor_setup',
      () => TwoFactorScreen(enabled: false, api: FakeSecurityApi()));
  _golden('acct_two_factor_off',
      () => TwoFactorScreen(enabled: true, api: FakeSecurityApi()));
  _golden('acct_issue_code',
      () => IssueResetCodeScreen(selfId: 'me', api: FakeSecurityApi()));
  _golden('acct_privacy', () => const PrivacyPolicyScreen());
  _golden('acct_privacy', () => const PrivacyPolicyScreen(), scale: 2);
  _golden('acct_server', () => const ServerConfigScreen());
  _golden('acct_server', () => const ServerConfigScreen(), scale: 2);
  _golden('acct_add_locations',
      () => const AddLocationsScreen(circleName: 'Frank Family', step: 6));
  _golden(
      'acct_add_locations',
      () => const AddLocationsScreen(circleName: 'Frank Family', step: 6),
      scale: 2);
  _golden('acct_member_edit',
      () => const MemberEditScreen(memberId: 'm', initialName: 'Frank'));
  _golden('acct_member_profile', () => const MemberProfileScreen(member: _frank));
  _golden('acct_member_profile', () => const MemberProfileScreen(member: _frank),
      scale: 2);
  _golden(
      'acct_people',
      () => PeopleScreen(
            circleName: 'Frank Family',
            members: ValueNotifier<List<Member>>(const [_frank, _june]),
          ));
  _golden(
      'acct_people_empty',
      () => PeopleScreen(
            circleName: 'Frank Family',
            members: ValueNotifier<List<Member>>(const []),
          ));
  _golden('acct_settings', () => const SettingsScreen());
  _golden('acct_settings', () => const SettingsScreen(), scale: 2);
  _golden('acct_circle_create', () => CircleCreateScreen(service: FakeCircleService()));
}
