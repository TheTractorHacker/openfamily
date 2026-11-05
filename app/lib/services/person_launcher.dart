import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';

/// Opens a `tel:`, `sms:` or `geo:` link in the phone's own app. Returns false
/// when nothing could handle it. Tests inject a fake instead.
typedef UriLauncher = Future<bool> Function(Uri uri);

/// Default launcher: Android only (the same android_intent_plus dependency the
/// emergency dialer uses). `tel:` only opens the dialer; the user presses call.
Future<bool> launchPersonUri(Uri uri) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  final String action = switch (uri.scheme) {
    'tel' => 'android.intent.action.DIAL',
    'sms' => 'android.intent.action.SENDTO',
    _ => 'android.intent.action.VIEW',
  };
  try {
    await AndroidIntent(action: action, data: uri.toString()).launch();
    return true;
  } catch (_) {
    return false;
  }
}
