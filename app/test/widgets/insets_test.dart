import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/app_shell.dart';
import 'package:openfamily/screens/circle_create_screen.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:openfamily/widgets/location_tab_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/circles_screens_test.dart' show FakeCircleService;
import '../support/golden_utils.dart';
import '../support/location_fixtures.dart';

/// Regression tests for edge-to-edge insets and the large-screen layout
/// rules: the harness applies a device's status bar / cutout / gesture bar
/// as real MediaQuery insets (see test/support/golden_utils.dart).

Widget _location() => LocationTabView(
  map: const FakeMap(),
  circleName: 'Frank Family',
  circles: kCircles,
  members: const <Member>[kSelf, kDriver],
  selfId: 'me',
  placesLoader: fakePlaces,
  onCheckIn: () {},
  onSos: () {},
  onOpenSettings: () {},
  onInvite: () {},
  onToggleSatellite: () {},
  onLocate: () {},
);

Widget _shell() => AppShell(
  tabBuilders: <AppTab, WidgetBuilder>{AppTab.location: (_) => _location()},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('system bar insets', () {
    testWidgets('bottom NavigationBar clears the gesture bar', (t) async {
      await pumpOnDevice(t, _shell(), spec: kS26, chrome: false);
      final Rect bar = t.getRect(find.byType(NavigationBar));
      // Bar grows by the gesture inset and sits flush with the screen bottom.
      expect(bar.bottom, kS26.size.height);
      expect(bar.height, 68 + kS26.padding.bottom);
      // Its labels stay above the gesture area.
      expect(
        t.getRect(find.text('Location')).bottom,
        lessThanOrEqualTo(kS26.size.height - kS26.padding.bottom),
      );
    });

    testWidgets('bottom bar is not drawn on wide screens', (t) async {
      await pumpOnDevice(t, _shell(), spec: kWide840L, chrome: false);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      // The rail stays right of the display cutout and inside the bars.
      final Rect rail = t.getRect(find.byType(NavigationRail));
      expect(rail.left, greaterThanOrEqualTo(kWide840L.padding.left));
      expect(rail.top, greaterThanOrEqualTo(kWide840L.padding.top));
      expect(
        rail.bottom,
        lessThanOrEqualTo(kWide840L.size.height - kWide840L.padding.bottom),
      );
    });

    testWidgets('floating map controls clear the status bar and nav bar', (
      t,
    ) async {
      await pumpOnDevice(t, _shell(), spec: kS26, chrome: false);
      // Top row sits below the status bar / cutout.
      expect(
        t.getRect(find.byTooltip('Settings')).top,
        greaterThanOrEqualTo(kS26.padding.top),
      );
      // Locate button is above the bottom bar.
      final double bar = kS26.size.height - (68 + kS26.padding.bottom);
      expect(t.getRect(find.byTooltip('Center on my location')).bottom,
          lessThanOrEqualTo(bar));
      expect(t.getRect(find.text('SOS')).bottom, lessThanOrEqualTo(bar));
    });

    testWidgets('two-pane: controls clear the gesture bar, no sheet', (
      t,
    ) async {
      await pumpOnDevice(t, _shell(), spec: kWide840L, chrome: false);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.text('People'), findsOneWidget);
      final double safeBottom =
          kWide840L.size.height - kWide840L.padding.bottom;
      expect(t.getRect(find.text('SOS')).bottom, lessThanOrEqualTo(safeBottom));
      expect(
        t.getRect(find.byTooltip('Settings')).top,
        greaterThanOrEqualTo(kWide840L.padding.top),
      );
      // The side panel starts below the status bar.
      expect(
        t.getRect(find.text('People')).top,
        greaterThanOrEqualTo(kWide840L.padding.top),
      );
    });

    testWidgets('phone portrait keeps the bottom sheet', (t) async {
      await pumpOnDevice(t, _shell(), spec: kPhone360, chrome: false);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('app bar title is below the status bar', (t) async {
      await pumpOnDevice(
        t,
        CircleCreateScreen(service: FakeCircleService()),
        spec: kS26,
        chrome: false,
      );
      expect(
        t.getRect(find.text('New circle')).top,
        greaterThanOrEqualTo(kS26.padding.top),
      );
    });
  });

  group('keyboard insets', () {
    testWidgets('place picker: Save stays above the keyboard', (t) async {
      await pumpOnDevice(
        t,
        const PlacePickerScreen(
          placeName: 'Grandma',
          icon: Icons.favorite,
          initial: Place(
            id: 'p',
            name: 'Grandma',
            icon: Icons.favorite,
            address: 'x',
            position: LatLng(39.8, -89.6),
            radiusMeters: 150,
          ),
        ),
        spec: kPhone360,
        keyboard: 300,
        chrome: false,
        settle: false,
      );
      await t.pump(const Duration(milliseconds: 200));
      final Rect save = t.getRect(find.widgetWithText(DsPillButton, 'Save place'));
      expect(save.bottom, lessThanOrEqualTo(kPhone360.size.height - 300));
      expect(save.top, greaterThan(0));
    });

    testWidgets('DsPage form: pinned action stays above the keyboard', (
      t,
    ) async {
      await pumpOnDevice(
        t,
        CircleCreateScreen(service: FakeCircleService()),
        spec: kS26,
        keyboard: 300,
        chrome: false,
      );
      final Rect b = t.getRect(find.widgetWithText(DsPillButton, 'Create circle'));
      expect(b.bottom, lessThanOrEqualTo(kS26.size.height - 300));
    });
  });

  group('content width and breakpoints', () {
    testWidgets('DsBody caps width and centers it', (t) async {
      await pumpOnDevice(
        t,
        const Scaffold(body: DsBody(child: SizedBox.expand(key: Key('c')))),
        spec: kWide840L,
        chrome: false,
      );
      final Rect r = t.getRect(find.byKey(const Key('c')));
      expect(r.width, kContentMaxWidth);
      // Centered in the area right of the 44 dp cutout.
      expect(r.center.dx, closeTo((44 + kWide840L.size.width) / 2, 1));
    });

    testWidgets('DsBody does not narrow a phone', (t) async {
      await pumpOnDevice(
        t,
        const Scaffold(body: DsBody(child: SizedBox.expand(key: Key('c')))),
        spec: kPhone412,
        chrome: false,
      );
      expect(t.getRect(find.byKey(const Key('c'))).width, 412);
    });

    testWidgets('DsPage form is capped at 560 dp on a wide screen', (t) async {
      await pumpOnDevice(
        t,
        const DsPage(
          title: 'Form',
          children: <Widget>[SizedBox(key: Key('f'), height: 10)],
        ),
        spec: kFold600,
        chrome: false,
      );
      // 560 minus 2 x 24 dp gutter.
      expect(t.getRect(find.byKey(const Key('f'))).width, 560 - 48);
    });

    test('rail breakpoint', () {
      expect(AppShell.useRail(const Size(412, 915)), isFalse);
      expect(AppShell.useRail(const Size(480, 1040)), isFalse);
      expect(AppShell.useRail(const Size(600, 960)), isFalse);
      expect(AppShell.useRail(const Size(840, 480)), isTrue);
      expect(AppShell.useRail(const Size(840, 1200)), isTrue);
      expect(AppShell.useRail(const Size(800, 360)), isTrue);
    });
  });

  group('system overlay style', () {
    test('icons are dark on Ice and light on Night, bars transparent', () {
      final SystemUiOverlayStyle light = systemOverlayFor(Brightness.light);
      final SystemUiOverlayStyle dark = systemOverlayFor(Brightness.dark);
      expect(light.statusBarIconBrightness, Brightness.dark);
      expect(light.systemNavigationBarIconBrightness, Brightness.dark);
      expect(dark.statusBarIconBrightness, Brightness.light);
      expect(dark.systemNavigationBarIconBrightness, Brightness.light);
      for (final SystemUiOverlayStyle s in <SystemUiOverlayStyle>[light, dark]) {
        expect(s.statusBarColor, Colors.transparent);
        expect(s.systemNavigationBarColor, Colors.transparent);
        expect(s.systemNavigationBarContrastEnforced, isFalse);
      }
    });

    testWidgets('app bar uses the themed overlay, never opaque black', (
      t,
    ) async {
      expect(
        buildLightTheme().appBarTheme.systemOverlayStyle?.systemNavigationBarColor,
        Colors.transparent,
      );
      expect(
        buildDarkTheme().appBarTheme.systemOverlayStyle?.statusBarIconBrightness,
        Brightness.light,
      );
    });
  });
}
