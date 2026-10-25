import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/location_tab_view.dart';

import '../support/location_fixtures.dart';

/// Golden renders of the Location tab. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens`.
/// Skipped otherwise so pixel comparison never gates a normal test run.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

Future<void> _loadRoboto() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final File f = File(
    '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  final File b = File(
    '$root/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf',
  );
  if (!f.existsSync()) return;
  final FontLoader l = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  if (b.existsSync()) {
    l.addFont(Future.value(ByteData.sublistView(b.readAsBytesSync())));
  }
  await l.load();
  final File icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final FontLoader il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

Widget _view(ThemeData theme) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
    ),
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(390, 760),
        padding: EdgeInsets.only(top: 28),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: 'Roboto'),
        child: LocationTabView(
          map: const FakeMap(),
          circleName: 'Frank Family',
          circles: kCircles,
          members: const <Member>[kSelf, kDriver, kAtHome, kOffline],
          selfId: 'me',
          placesLoader: fakePlaces,
          onCheckIn: () {},
          onSos: () {},
          onOpenSettings: () {},
          onInvite: () {},
          onToggleSatellite: () {},
          onLocate: () {},
        ),
      ),
    ),
  );
}

Future<void> _shot(
  WidgetTester t,
  String name,
  ThemeData theme, {
  bool dragUp = false,
  bool placesTab = false,
}) async {
  t.view.physicalSize = const Size(780, 1520);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(_view(theme));
  await t.pump();
  if (placesTab) {
    await t.tap(find.text('Places'));
    await t.pumpAndSettle();
  }
  if (dragUp) {
    await t.fling(find.text('People'), const Offset(0, -330), 1500);
    await t.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('$name.png'));
}

void main() {
  setUpAll(_loadRoboto);
  testWidgets(
    'location tab light, peek',
    (t) => _shot(t, 'location_light_peek', buildLightTheme()),
    skip: !_on,
  );
  testWidgets(
    'location tab dark, peek',
    (t) => _shot(t, 'location_dark_peek', buildDarkTheme()),
    skip: !_on,
  );
  testWidgets(
    'location tab light, half',
    (t) => _shot(t, 'location_light_half', buildLightTheme(), dragUp: true),
    skip: !_on,
  );
  testWidgets(
    'location tab dark, half',
    (t) => _shot(t, 'location_dark_half', buildDarkTheme(), dragUp: true),
    skip: !_on,
  );
  testWidgets(
    'places tab dark',
    (t) => _shot(
      t,
      'places_dark',
      buildDarkTheme(),
      dragUp: true,
      placesTab: true,
    ),
    skip: !_on,
  );
}
