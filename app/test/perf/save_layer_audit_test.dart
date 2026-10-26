// Guard: the widgets that force an offscreen buffer (saveLayer) in the render
// pipeline are few and deliberate. A new one must be added here on purpose.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const Map<String, int> kAllowed = <String, int>{
  // Disabled-state dimming only (opacity 1.0 paints without a layer).
  'lib/widgets/ds/pill_button.dart|Opacity(': 1,
  'lib/widgets/ds/toggle_row.dart|Opacity(': 1,
  'lib/screens/safety_screen.dart|Opacity(': 2,
  // Floating action row: layer only during the 150 ms cross-fade.
  'lib/widgets/location_tab_view.dart|AnimatedOpacity(': 1,
};

const List<String> kTokens = <String>[
  'Opacity(',
  'BackdropFilter(',
  'ShaderMask(',
  'ColorFiltered(',
  'ImageFiltered(',
  'Clip.antiAliasWithSaveLayer',
  'FadeTransition(',
];

void main() {
  test('saveLayer-inducing widgets match the audited allow-list', () {
    final Map<String, int> found = <String, int>{};
    for (final FileSystemEntity f
        in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String src = f.readAsStringSync();
      for (final String t in kTokens) {
        // Count real widget uses: "Opacity(" not preceded by an identifier
        // character (so AnimatedOpacity( is counted under its own name).
        final RegExp re = RegExp('(?<![A-Za-z])${RegExp.escape(t)}');
        final int n = re.allMatches(src).length;
        if (n > 0) found['${f.path}|$t'] = n;
        if (t == 'Opacity(') {
          final int a = RegExp('AnimatedOpacity\\(').allMatches(src).length;
          if (a > 0) found['${f.path}|AnimatedOpacity('] = a;
        }
      }
    }
    // ignore: avoid_print
    print('PERFMETRIC saveLayer sources: ${found.values.fold(0, (a, b) => a + b)}'
        ' (BackdropFilter/ShaderMask/ColorFiltered/ImageFiltered: '
        '${found.keys.where((k) => !k.contains('Opacity')).length})');
    expect(found, kAllowed);
  });
}
