// Settings scroll cost: what a fling through the Settings page does on the UI
// isolate (rebuilds, platform-channel traffic, repaints of the dotted
// background) and how many draw operations the background costs the raster
// thread on every frame.
//
// Measured on main (v0.26.26) with this same harness (only a paint counter
// added), before the fix:
//   dot-grid-ops(412x915): 10488 drawCircle calls, replayed by the raster
//     thread on every frame;
//   settings-scroll: DotGridPainter.paint=41 (each one re-recording the
//     10488 circles on the UI thread while the app bar animated its
//     scrolled-under colour), SettingsScreen rebuilds=0, platform
//     messages=3 (LiveText.isLiveTextInputAvailable, Clipboard.hasStrings,
//     ProcessText.queryTextActions: the search field was recreated each
//     time it scrolled back into view).
// After: 1 drawRawPoints, 0 repaints, 0 rebuilds, 0 platform messages.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/dot_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/build_counter.dart';

/// Counts every call made on a canvas, by method name.
class _CountingCanvas implements Canvas {
  final Map<String, int> calls = <String, int>{};
  int get total => calls.values.fold(0, (int a, int b) => a + b);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final String name = invocation.memberName.toString();
    calls[name] = (calls[name] ?? 0) + 1;
    return null;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('the dotted background is a handful of draw operations, not one per dot', () {
    final _CountingCanvas canvas = _CountingCanvas();
    const DotGridPainter(color: Color(0x22000000)).paint(canvas, const Size(412, 915));
    // ignore: avoid_print
    print('PERFMETRIC dot-grid-ops(412x915): ${canvas.total} ${canvas.calls}');
    expect(canvas.total, lessThanOrEqualTo(4));
  });

  testWidgets('scrolling Settings: no page rebuilds, no platform calls, background not repainted',
      (WidgetTester t) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildLightTheme(), home: const SettingsScreen()));
    await t.pump(const Duration(milliseconds: 300));

    int messages = 0;
    t.binding.defaultBinaryMessenger.allMessagesHandler =
        (String? channel, MessageHandler? handler, ByteData? message) async {
      messages++;
      return null;
    };
    addTearDown(() => t.binding.defaultBinaryMessenger.allMessagesHandler = null);

    final int paintsBefore = DotGridPainter.debugPaintCount;
    final BuildCounter c = BuildCounter()..start();
    // Three slow drags down (scrolled-under app bar animates) and one back up.
    for (int i = 0; i < 3; i++) {
      await t.drag(find.byType(ListView), const Offset(0, -300));
      await t.pump(const Duration(milliseconds: 16));
      for (int f = 0; f < 15; f++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }
    await t.fling(find.byType(ListView), const Offset(0, 900), 3000);
    for (int f = 0; f < 60; f++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    c.stop();
    final int paints = DotGridPainter.debugPaintCount - paintsBefore;
    // ignore: avoid_print
    print('PERFMETRIC settings-scroll: DotGridPainter.paint=$paints '
        'SettingsScreen=${c.of('SettingsScreen')} platformMessages=$messages '
        'DsListRow=${c.of('DsListRow')} DsToggleRow=${c.of('DsToggleRow')}');
    expect(c.of('SettingsScreen'), 0, reason: 'scrolling must not rebuild the page');
    expect(messages, 0, reason: 'scrolling must not reach the platform');
    expect(paints, 0, reason: 'the background sits behind its own repaint boundary');
  });
}
