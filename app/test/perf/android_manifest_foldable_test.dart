// Locks the Android manifest settings a foldable needs: a fold, unfold,
// rotation or multi-window resize must be handled by the running Flutter
// engine (no activity restart), the app must be resizable and rotatable, and
// nothing may switch off the GPU renderer.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String xml =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final RegExp activity =
      RegExp(r'<activity\b[^>]*android:name="\.MainActivity"[^>]*>', dotAll: true);

  test('MainActivity absorbs fold / resize / density changes without a restart', () {
    final String tag = activity.firstMatch(xml)!.group(0)!;
    final String changes =
        RegExp(r'android:configChanges="([^"]*)"').firstMatch(tag)!.group(1)!;
    final Set<String> set = changes.split('|').toSet();
    for (final String needed in <String>[
      'screenSize', 'smallestScreenSize', 'screenLayout', 'orientation',
      'density', 'uiMode', 'keyboard', 'keyboardHidden', 'fontScale',
      'layoutDirection', 'locale',
    ]) {
      expect(set, contains(needed), reason: 'configChanges must include $needed');
    }
  });

  test('app is resizable, rotatable and hardware accelerated', () {
    final String tag = activity.firstMatch(xml)!.group(0)!;
    expect(tag, contains('android:resizeableActivity="true"'));
    expect(tag, contains('android:hardwareAccelerated="true"'));
    expect(xml, isNot(contains('screenOrientation')),
        reason: 'portrait locks make the inner screen unusable (Play large-screen quality)');
    expect(xml, isNot(contains('maxAspectRatio')));
    expect(xml, isNot(contains('android.max_aspect')));
    expect(tag, contains('adjustResize'));
  });

  test('nothing disables Impeller or forces software rendering', () {
    expect(xml.toLowerCase(), isNot(contains('enableimpeller" android:value="false')));
    expect(xml.toLowerCase(), isNot(contains('enable-software-rendering')));
    expect(xml.toLowerCase(), isNot(contains('disableimpeller')));
    expect(xml, isNot(contains('android:hardwareAccelerated="false"')));
  });

  test('the app never forces an orientation from Dart', () {
    for (final FileSystemEntity f in Directory('lib').listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        expect(f.readAsStringSync(), isNot(contains('setPreferredOrientations')),
            reason: f.path);
      }
    }
  });
}
