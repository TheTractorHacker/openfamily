import 'dart:async';

import 'package:flutter/services.dart';

import 'invite_link.dart';

/// Receives invite links opened through Android intent filters.
///
/// MainActivity forwards the launching intent's data URI over the
/// `app.openfamily/links` channel: `getInitialLink` for a cold start and a
/// `link` call whenever a new intent arrives while the app is running.
class DeepLinkService {
  DeepLinkService._();

  static const MethodChannel _channel = MethodChannel('app.openfamily/links');

  /// The invite link that launched the app, if any.
  static Future<InviteLink?> initialLink() async {
    try {
      final String? raw = await _channel.invokeMethod<String>('getInitialLink');
      return raw == null ? null : InviteLink.parse(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Calls [onLink] for each invite link received while the app is running.
  static void listen(void Function(InviteLink link) onLink) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'link') return;
      final Object? raw = call.arguments;
      if (raw is! String) return;
      final InviteLink? link = InviteLink.parse(raw);
      if (link != null) onLink(link);
    });
  }
}
