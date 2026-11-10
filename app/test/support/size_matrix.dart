import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/theme/app_theme.dart';

/// The windows Orbitly must fit, in dp (device pixel ratio 1): the Galaxy Z
/// Fold 4 cover display (about 344 x 882), a small phone, a large phone and
/// the Fold's inner display.
const Map<String, Size> kLayoutSizes = <String, Size>{
  'fold-cover 344x882': Size(344, 882),
  'small 360x640': Size(360, 640),
  'large 412x915': Size(412, 915),
  'fold-inner 673x840': Size(673, 840),
};

/// Text scales the layouts are checked at.
const List<double> kLayoutScales = <double>[1.0, 1.5];

void setWindow(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

/// [child] in a themed app at a fixed text [scale].
Widget scaled(Widget child, double scale) => MaterialApp(
      theme: buildLightTheme(),
      builder: (BuildContext context, Widget? app) => MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: app!,
      ),
      home: child,
    );

/// Runs [body] once per size and scale; a RenderFlex overflow (or any other
/// framework error) in [body] fails the test and names the combination.
void layoutMatrix(
  String name,
  Future<void> Function(WidgetTester t, Size size, double scale) body, {
  Map<String, Size> sizes = kLayoutSizes,
}) {
  for (final MapEntry<String, Size> s in sizes.entries) {
    for (final double scale in kLayoutScales) {
      testWidgets('$name at ${s.key}, text x$scale', (WidgetTester t) async {
        setWindow(t, s.value);
        await body(t, s.value, scale);
        expect(t.takeException(), isNull, reason: 'overflow or error at ${s.key}, text x$scale');
      });
    }
  }
}
