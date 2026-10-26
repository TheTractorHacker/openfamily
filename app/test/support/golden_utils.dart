import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/theme/app_theme.dart';

/// Reusable harness for "device class" goldens and inset tests.
///
/// A [DeviceSpec] describes a phone/tablet by logical size, pixel ratio and
/// the system insets Android reports under edge-to-edge (status bar, display
/// cutout, gesture bar). [pumpOnDevice] applies it to the test view so the
/// real `MediaQuery.viewPadding / padding / viewInsets` seen by the app match
/// the device, and optionally paints fake system bars and a keyboard so a
/// golden shows whether content collides with them.
///
/// Goldens run only with `OF_GOLDENS=1` (see [goldensOn]).
final bool goldensOn = Platform.environment['OF_GOLDENS'] == '1';

@immutable
class DeviceSpec {
  const DeviceSpec(
    this.name,
    this.size, {
    this.padding = EdgeInsets.zero,
    this.dpr = 1,
  });

  final String name;

  /// Logical size in dp.
  final Size size;

  /// System bar / cutout insets in dp (what Android reports).
  final EdgeInsets padding;
  final double dpr;

  /// Landscape orientation.
  bool get landscape => size.width > size.height;
}

/// Common compact phone (360x800), status bar 28, gesture bar 24.
const DeviceSpec kPhone360 = DeviceSpec(
  '360x800',
  Size(360, 800),
  padding: EdgeInsets.only(top: 28, bottom: 24),
);

/// Typical 412x915 phone.
const DeviceSpec kPhone412 = DeviceSpec(
  '412x915',
  Size(412, 915),
  padding: EdgeInsets.only(top: 36, bottom: 24),
);

/// Galaxy S26 Ultra class: about 480 dp wide, 1040 dp tall, tall status bar
/// with the punch-hole, gesture navigation.
const DeviceSpec kS26 = DeviceSpec(
  '480x1040',
  Size(480, 1040),
  padding: EdgeInsets.only(top: 44, bottom: 24),
);

/// Foldable inner screen / small tablet, portrait.
const DeviceSpec kFold600 = DeviceSpec(
  '600x960',
  Size(600, 960),
  padding: EdgeInsets.only(top: 36, bottom: 24),
);

/// 840 dp wide landscape (cutout on the left, 24 dp status and gesture bars).
const DeviceSpec kWide840L = DeviceSpec(
  '840x480L',
  Size(840, 480),
  padding: EdgeInsets.only(left: 44, top: 24, bottom: 24),
);

/// S26 Ultra in landscape.
const DeviceSpec kS26L = DeviceSpec(
  '1040x480L',
  Size(1040, 480),
  padding: EdgeInsets.only(left: 44, top: 24, bottom: 24),
);

Future<void> loadGoldenFonts() async {
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

/// Applies [spec] to the test view: physical size, pixel ratio, system
/// insets, and an optional soft keyboard of [keyboard] dp. When the keyboard
/// is up Android keeps `viewPadding` (system bars) but `padding` loses the
/// part the keyboard covers; this mirrors that.
void applyDevice(
  WidgetTester t,
  DeviceSpec spec, {
  double keyboard = 0,
}) {
  final double r = spec.dpr;
  t.view.physicalSize = Size(spec.size.width * r, spec.size.height * r);
  t.view.devicePixelRatio = r;
  final EdgeInsets p = spec.padding;
  FakeViewPadding fp(EdgeInsets e) => FakeViewPadding(
    left: e.left * r,
    top: e.top * r,
    right: e.right * r,
    bottom: e.bottom * r,
  );
  t.view.viewPadding = fp(p);
  t.view.padding = fp(
    keyboard > 0
        ? p.copyWith(bottom: (p.bottom - keyboard).clamp(0, double.infinity))
        : p,
  );
  t.view.viewInsets = FakeViewPadding(bottom: keyboard * r);
  addTearDown(() {
    t.view.reset();
    t.view.resetPadding();
    t.view.resetViewPadding();
    t.view.resetViewInsets();
  });
}

/// A MaterialApp with the golden font, a text scale and optional bold text.
Widget goldenApp(
  Widget home,
  ThemeData theme, {
  double textScale = 1,
  bool boldText = false,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
      navigationBarTheme: theme.navigationBarTheme.copyWith(
        labelTextStyle: WidgetStateProperty.resolveWith(
          (Set<WidgetState> st) => theme.navigationBarTheme.labelTextStyle
              ?.resolve(st)
              ?.copyWith(fontFamily: 'Roboto'),
        ),
      ),
      navigationRailTheme: theme.navigationRailTheme.copyWith(
        selectedLabelTextStyle: theme.navigationRailTheme.selectedLabelTextStyle
            ?.copyWith(fontFamily: 'Roboto'),
        unselectedLabelTextStyle: theme
            .navigationRailTheme
            .unselectedLabelTextStyle
            ?.copyWith(fontFamily: 'Roboto'),
      ),
      listTileTheme: theme.listTileTheme.copyWith(
        titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
          fontFamily: 'Roboto',
        ),
        subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
          fontFamily: 'Roboto',
        ),
      ),
    ),
    builder: (BuildContext c, Widget? child) => MediaQuery(
      data: MediaQuery.of(
        c,
      ).copyWith(textScaler: TextScaler.linear(textScale), boldText: boldText),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: 'Roboto'),
        child: child!,
      ),
    ),
    home: home,
  );
}

const ValueKey<String> kGoldenRoot = ValueKey<String>('golden-root');

/// Paints fake status bar, cutout, gesture pill and keyboard over [child] so
/// collisions are visible in a screenshot. Purely a test aid.
class FakeSystemChrome extends StatelessWidget {
  const FakeSystemChrome({
    super.key,
    required this.spec,
    required this.dark,
    required this.child,
    this.keyboard = 0,
  });

  final DeviceSpec spec;
  final bool dark;
  final double keyboard;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets p = spec.padding;
    final Color ink = dark ? Colors.white : Colors.black;
    final Color glass = (dark ? Colors.black : Colors.white).withValues(
      alpha: 0.0,
    );
    return RepaintBoundary(
      key: kGoldenRoot,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: child),
            if (p.top > 0)
              Positioned(
                left: p.left,
                right: p.right,
                top: 0,
                height: p.top,
                child: ColoredBox(
                  color: glass,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const SizedBox(width: 16),
                      Text(
                        '9:41',
                        style: TextStyle(
                          color: ink,
                          fontSize: 12,
                          fontFamily: 'Roboto',
                          decoration: TextDecoration.none,
                        ),
                      ),
                      Icon(Icons.signal_cellular_alt, color: ink, size: 14),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            if (p.left > 0 && spec.landscape ||
                (!spec.landscape && p.top >= 40))
              Positioned(
                left: spec.landscape ? 12 : spec.size.width / 2 - 7,
                top: spec.landscape ? spec.size.height / 2 - 7 : 8,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            if (keyboard > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: keyboard,
                child: ColoredBox(
                  color: dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D5DB),
                  child: Center(
                    child: Text(
                      'keyboard',
                      style: TextStyle(
                        color: ink.withValues(alpha: 0.5),
                        fontSize: 14,
                        fontFamily: 'Roboto',
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            if (p.bottom > 0 && keyboard == 0)
              Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: 108,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ink.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Pumps [home] on [spec] (theme, text scale, keyboard) and returns once
/// settled. Assert insets with `tester.getRect`, or compare a golden with
/// [expectGolden].
Future<void> pumpOnDevice(
  WidgetTester t,
  Widget home, {
  DeviceSpec spec = kS26,
  bool dark = false,
  double textScale = 1,
  bool boldText = false,
  double keyboard = 0,
  bool chrome = true,
  bool settle = true,
}) async {
  applyDevice(t, spec, keyboard: keyboard);
  final Widget app = goldenApp(
    home,
    dark ? buildDarkTheme() : buildLightTheme(),
    textScale: textScale,
    boldText: boldText,
  );
  await t.pumpWidget(
    chrome
        ? FakeSystemChrome(
            spec: spec,
            dark: dark,
            keyboard: keyboard,
            child: app,
          )
        : app,
  );
  // Let asset images decode before the first frame is captured.
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> expectGolden(WidgetTester t, String file) =>
    expectLater(find.byKey(kGoldenRoot), matchesGoldenFile(file));
