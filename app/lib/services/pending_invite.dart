import 'package:flutter/foundation.dart';

import 'invite_link.dart';
import 'server_config.dart';

/// An invite opened from a link or QR code that has not been redeemed yet.
///
/// Screens in the join/register flow read [code] to pre-fill their field and
/// call [clear] once the invite is used.
class PendingInvite {
  PendingInvite._();

  static final ValueNotifier<InviteLink?> current =
      ValueNotifier<InviteLink?>(null);

  /// The pending code, or null.
  static String? get code => current.value?.code;

  static void clear() => current.value = null;

  /// Records [link] and points the app at its server when the app is not yet
  /// configured. If a different server is already configured the link is
  /// still recorded and `false` is returned so the caller can warn: switching
  /// servers silently could send credentials somewhere unexpected.
  static Future<bool> accept(InviteLink link) async {
    final ServerConfig cfg = ServerConfig.instance;
    if (!cfg.isConfigured) {
      await cfg.setUrl(link.server);
    } else if (cfg.apiBaseUrl != link.server) {
      current.value = null;
      return false;
    }
    current.value = link;
    return true;
  }
}
