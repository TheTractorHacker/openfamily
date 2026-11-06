import 'package:flutter/services.dart';

/// iOS stand-in for android_intent_plus: asks the Swift side
/// (LinkBridge.swift, channel `app.openfamily/launcher`) to open a `tel:`,
/// `sms:`, `otpauth:` or Apple Maps URL. Returns false when nothing handled it
/// or the channel is missing. The native side refuses every other scheme.
class NativeUriOpener {
  const NativeUriOpener._();

  static MethodChannel channel = const MethodChannel('app.openfamily/launcher');

  static Future<bool> open(String uri) async {
    try {
      return (await channel.invokeMethod<bool>('open', uri)) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
