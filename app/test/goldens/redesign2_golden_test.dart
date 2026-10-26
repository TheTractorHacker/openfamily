import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/screens/circle_detail_screen.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/screens/create_circle_screen.dart';
import 'package:openfamily/screens/create_or_join_circle_screen.dart';
import 'package:openfamily/screens/invite_screen.dart';
import 'package:openfamily/screens/join_circle_screen.dart';
import 'package:openfamily/screens/login_screen.dart';
import 'package:openfamily/screens/permissions_screen.dart';
import 'package:openfamily/screens/reset_password_screen.dart';
import 'package:openfamily/screens/security_screen.dart';
import 'package:openfamily/screens/sign_up_screen.dart';
import 'package:openfamily/screens/welcome_screen.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/theme/app_theme.dart';

import '../screens/circles_screens_test.dart' show FakeCircleService;
import '../support/fake_security_api.dart';

/// Golden renders of the second-wave redesign. Run with
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

class _NeverService extends FakeCircleService {
  @override
  Future<List<Circle>> listCircles() => Completer<List<Circle>>().future;
}

void main() {
  setUpAll(_loadFonts);

  _golden('r2_welcome', () => const WelcomeScreen());
  _golden('r2_welcome', () => const WelcomeScreen(), scale: 2);
  _golden('r2_signup', () => const SignUpScreen());
  _golden('r2_login', () => const LoginScreen());
  _golden('r2_login', () => const LoginScreen(), scale: 2);
  _golden(
    'r2_reset',
    () => const ResetPasswordScreen(initialEmail: 'alex@example.com'),
  );
  _golden('r2_create_or_join', () => const CreateOrJoinCircleScreen());
  _golden('r2_create_family', () => const CreateCircleScreen());
  _golden('r2_join', () => JoinCircleScreen(step: 4, onDone: () {}));
  _golden('r2_invite', () => const InviteScreen(circleName: 'Frank Family', step: 5));
  _golden('r2_permissions', () => const PermissionsScreen());
  _golden('r2_permissions', () => const PermissionsScreen(), scale: 2);
  _golden('r2_circles', () => CirclesScreen(service: FakeCircleService()));
  _golden(
    'r2_circles_loading',
    () => CirclesScreen(service: _NeverService()),
    settle: false,
  );
  _golden(
    'r2_circles_offline',
    () => CirclesScreen(
      service: FakeCircleService()..listError = const CircleException('No connection', offline: true),
    ),
  );
  _golden(
    'r2_circle_detail',
    () => CircleDetailScreen(
      circle: FakeCircleService().circles.first,
      service: FakeCircleService(),
    ),
  );
  _golden(
    'r2_security',
    () => SecurityScreen(
      api: FakeSecurityApi(
        account: const AccountInfo(
          id: 'me',
          email: 'a@b.c',
          role: 'admin',
          totpEnabled: true,
        ),
      ),
    ),
  );
}
