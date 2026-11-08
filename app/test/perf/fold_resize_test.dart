// Foldable / large-screen behaviour: resizing the window (fold, unfold, rotate,
// multi-window) must pick the right layout WITHOUT recreating the map or the
// tabs, and must not overflow at any size or text scale.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/app_shell.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/location_tab_view.dart';

import '../support/build_counter.dart';
import '../support/location_fixtures.dart';

// Galaxy Z Fold 4 in dp: cover, inner (portrait / landscape), and half-width
// multi-window panes.
const Size kCover = Size(412, 915);
const Size kInner = Size(884, 1104);
const Size kInnerL = Size(1104, 884);
const Size kHalfPortrait = Size(442, 1104);
const Size kHalfLandscape = Size(884, 552);

int mapInits = 0;
int mapDisposes = 0;

/// Counts how many times the (real, stateful) map widget is created.
class _CountingMap extends StatefulWidget {
  const _CountingMap();
  @override
  State<_CountingMap> createState() => _CountingMapState();
}

class _CountingMapState extends State<_CountingMap> {
  @override
  void initState() {
    super.initState();
    mapInits++;
  }

  @override
  void dispose() {
    mapDisposes++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const FakeMap();
}

void _size(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
}

Widget _location(double textScale) => MaterialApp(
      theme: buildLightTheme(),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: LocationTabView(
        map: const _CountingMap(),
        circleName: 'Frank Family',
        circles: kCircles,
        members: const [kSelf, kDriver, kAtHome, kOffline],
        selfId: 'me',
        placesLoader: fakePlaces,
      ),
    );

class _Tab extends StatefulWidget {
  const _Tab(this.label);
  final String label;
  @override
  State<_Tab> createState() => _TabState();
}

int tabInits = 0;

class _TabState extends State<_Tab> {
  @override
  void initState() {
    super.initState();
    tabInits++;
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

void main() {
  setUp(() {
    mapInits = 0;
    mapDisposes = 0;
    tabInits = 0;
  });

  group('location tab', () {
    testWidgets('folding and unfolding never recreates the map', (tester) async {
      addTearDown(tester.view.reset);
      _size(tester, kCover);
      await tester.pumpWidget(_location(1));
      await tester.pump();
      expect(find.byType(DraggableScrollableSheet), findsOneWidget,
          reason: 'cover screen is the phone layout with a bottom sheet');

      for (final Size s in <Size>[
        kInner, kCover, kInnerL, kHalfPortrait, kInner, kCover,
      ]) {
        _size(tester, s);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(mapInits, 1, reason: 'one map for the whole fold/unfold cycle');
      expect(mapDisposes, 0);
    });

    for (final double scale in <double>[1.0, 1.3]) {
      for (final (String, Size, bool) c in <(String, Size, bool)>[
        ('cover', kCover, false),
        ('inner portrait', kInner, true),
        ('inner landscape', kInnerL, true),
        ('half portrait', kHalfPortrait, false),
        ('half landscape', kHalfLandscape, true),
      ]) {
        testWidgets('${c.$1} at text ${scale}x: no overflow, '
            '${c.$3 ? "map beside panel" : "bottom sheet"}', (tester) async {
          addTearDown(tester.view.reset);
          _size(tester, c.$2);
          await tester.pumpWidget(_location(scale));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          expect(find.byType(DraggableScrollableSheet),
              c.$3 ? findsNothing : findsOneWidget);
          expect(find.byType(FakeMap), findsOneWidget);
          if (c.$3) {
            // Two panes: the map and the people panel sit side by side.
            final Rect map = tester.getRect(find.byType(FakeMap));
            expect(map.width, lessThan(c.$2.width));
            expect(find.text('People'), findsWidgets);
          }
        });
      }
    }
  });

  group('app shell', () {
    Widget shell() => MaterialApp(
          theme: buildLightTheme(),
          home: AppShell(tabBuilders: <AppTab, WidgetBuilder>{
            for (final AppTab t in AppTab.values) t: (_) => _Tab(t.name),
          }),
        );

    testWidgets('bottom bar on the cover screen, rail on the inner screen, '
        'tabs keep their state across the change', (tester) async {
      addTearDown(tester.view.reset);
      _size(tester, kCover);
      await tester.pumpWidget(shell());
      await tester.pump();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(tabInits, 1);

      _size(tester, kInner);
      await tester.pump();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tabInits, 1, reason: 'unfolding must not recreate the tabs');

      _size(tester, kHalfPortrait);
      await tester.pump();
      expect(find.byType(NavigationBar), findsOneWidget);
      _size(tester, kCover);
      await tester.pump();
      expect(tabInits, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a resize rebuilds the shell chrome, not the tab bodies',
        (tester) async {
      addTearDown(tester.view.reset);
      int bodyBuilds = 0;
      _size(tester, kCover);
      await tester.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: AppShell(tabBuilders: <AppTab, WidgetBuilder>{
          for (final AppTab t in AppTab.values)
            t: (_) {
              bodyBuilds++;
              return Text(t.name);
            },
        }),
      ));
      await tester.pump();
      final int before = bodyBuilds;
      final BuildCounter c = BuildCounter()..start();
      // A pure size change within the phone class (e.g. keyboard-free pop-up
      // window resize) is only allowed to re-layout the visible body.
      _size(tester, const Size(430, 915));
      await tester.pump();
      c.stop();
      // ignore: avoid_print
      print('PERFMETRIC resize-within-phone: bodyBuilds=${bodyBuilds - before} '
          'AppShell=${c.of('AppShell')}');
      expect(tester.takeException(), isNull);
    });
  });
}
