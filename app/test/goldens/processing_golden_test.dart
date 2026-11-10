import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/my_processing_screen.dart';
import 'package:openfamily/screens/processing_policy_screen.dart';
import 'package:openfamily/screens/processing_screen.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart' show ProcessingViewer;
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_processing_controller.dart';

/// "UI polish 2", processing track: the circle processing setting, the member Server processing screen
/// and Settings > Server processing (docs/ux/UI_POLISH_2.md).
///
///   OF_GOLDENS=1 flutter test --update-goldens test/goldens/processing_golden_test.dart
///
/// writes `test/goldens/p2/proc_<screen>_<width>[_x15]_<light|dark>.png`. Skipped without OF_GOLDENS=1.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

Future<void> _loadFonts() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final String dir = '$root/bin/cache/artifacts/material_fonts';
  final FontLoader roboto = FontLoader('Roboto');
  for (final String n in <String>['Roboto-Regular', 'Roboto-Bold']) {
    final File f = File('$dir/$n.ttf');
    if (f.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
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
          titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
          subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'Roboto'),
        ),
      ),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
      ),
      home: home,
    );

class _Variant {
  const _Variant(this.width, this.scale, this.dark, {this.height = 844});
  final double width, scale, height;
  final bool dark;
  String get suffix => '${width.round()}${scale == 1 ? '' : '_x${(scale * 10).round()}'}_${dark ? 'dark' : 'light'}';
}

const List<_Variant> _tall = <_Variant>[
  _Variant(390, 1, true, height: 1700),
  _Variant(390, 1, false, height: 1700),
  _Variant(344, 1.5, true, height: 3200),
  _Variant(344, 1.5, false, height: 3200),
];

const List<_Variant> _variants = <_Variant>[
  _Variant(390, 1, true),
  _Variant(390, 1, false),
  _Variant(344, 1.5, true, height: 1000),
  _Variant(344, 1.5, false, height: 1000),
];

void _shoot(
  String name,
  Widget Function() screen, {
  Future<void> Function(WidgetTester)? after,
  List<_Variant> variants = _variants,
}) {
  for (final _Variant v in variants) {
    testWidgets('p2 $name ${v.suffix}', (WidgetTester t) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      t.view.physicalSize = Size(v.width * 2, v.height * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(screen(), v.dark ? buildDarkTheme() : buildLightTheme(), v.scale));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      if (after != null) await after(t);
      expect(t.takeException(), isNull, reason: 'overflow in $name ${v.suffix}');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('p2/${name}_${v.suffix}.png'));
    }, skip: !_on);
  }
}


const Circle _admin = Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Foley Family', role: 'admin', sharingEnabled: true, memberCount: 3, e2eeMode: 'private');
const Circle _member = Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Foley Family', role: 'member', sharingEnabled: true, memberCount: 3, e2eeMode: 'private');

class _Circles implements CircleService {
  @override
  Future<List<Circle>> listCircles() async => const <Circle>[
        Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Foley Family', role: 'member', sharingEnabled: true, memberCount: 3, e2eeMode: 'private'),
        Circle(id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'Soccer', role: 'member', sharingEnabled: true, memberCount: 9, e2eeMode: 'private'),
      ];
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  setUpAll(_loadFonts);
  const Map<String, int> mixed = <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone, pC: E2ee.linePhone};

  _shoot('proc_policy_admin', () => ProcessingPolicyScreen(
      circle: _admin,
      controller: FakeProcessingController(FakeProcessingController.snapshot(lanes: mixed, defaultForNew: E2ee.lineServer))));
  _shoot('proc_policy_required', () => ProcessingPolicyScreen(
      circle: _admin,
      controller: FakeProcessingController(
          FakeProcessingController.snapshot(lanes: mixed, defaultForNew: E2ee.lineServer, optOut: E2ee.optOutRequiredServer))));
  _shoot('proc_policy_nokey', () => ProcessingPolicyScreen(
      circle: _admin, controller: FakeProcessingController(FakeProcessingController.snapshot(assist: false, serverKey: false))));
  _shoot('proc_policy_member', () => ProcessingPolicyScreen(
      circle: _member,
      controller: FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, lanes: mixed), me: pB)));

  _shoot('proc_admin', () => ProcessingScreen(
      circle: _admin,
      controller: FakeProcessingController(FakeProcessingController.snapshot(
          lanes: mixed,
          unverified: const <String>{pC},
          viewers: const <ProcessingViewer>[ProcessingViewer('Alice', 'web'), ProcessingViewer('Alice', 'service')]))),
      variants: _tall);
  _shoot('proc_admin_required', () => ProcessingScreen(
      circle: _admin,
      controller: FakeProcessingController(FakeProcessingController.snapshot(lanes: mixed, optOut: E2ee.optOutRequiredServer, unverified: const <String>{pC}))),
      variants: _tall);
  _shoot('proc_member_choose', () => ProcessingScreen(
      circle: _member,
      controller: FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, lanes: mixed, defaultForNew: E2ee.lineServer, unverified: const <String>{pB}), me: pB)),
      variants: _tall);
  _shoot('proc_member_required', () => ProcessingScreen(
      circle: _member,
      controller: FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, lanes: mixed, optOut: E2ee.optOutRequiredServer), me: pB)),
      variants: _tall);

  _shoot('proc_my', () => MyProcessingScreen(
      circles: _Circles(),
      controller: FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, lanes: mixed), me: pB)));
}
