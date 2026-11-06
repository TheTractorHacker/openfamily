import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';

import 'native_uri_opener.dart';

/// Opens an `otpauth://` URI in an installed authenticator app.
///
/// Android (android_intent_plus) and iOS (LinkBridge.swift); other
/// platforms return false so the UI falls back to the copyable key.
class OtpauthLauncher {
  const OtpauthLauncher._();

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Only `otpauth://totp/...` URIs are ever handed to the OS.
  static bool isValidUri(String uri) {
    final Uri? parsed = Uri.tryParse(uri);
    return parsed != null && parsed.scheme == 'otpauth' && parsed.host == 'totp';
  }

  /// Returns false when no authenticator handled the link.
  static Future<bool> open(String uri) async {
    if (!isSupported || !isValidUri(uri)) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return NativeUriOpener.open(uri);
    }
    try {
      await AndroidIntent(action: 'action_view', data: uri).launch();
      return true;
    } catch (_) {
      return false;
    }
  }
}
