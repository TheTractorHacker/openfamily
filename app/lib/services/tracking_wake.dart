import 'dart:async';

import 'package:background_locator_2/background_locator.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;

import 'diagnostics/tracking_journal.dart';

/// What a server wake-up (the "location request" push) does for tracking itself.
///
/// The push already makes the app take one fresh fix. A push also wakes the
/// app's process when Android had ended it (UnifiedPush starts the app in the
/// background), so this is the moment to ask the native side to bring the
/// tracking service back if tracking is wanted but the service is gone.
///
/// Android only lets an app start a foreground service from the background in
/// a few cases (for example when the user has set the app's battery use to
/// Unrestricted). So this may be refused. The native side records the refusal
/// in its journal and this function records the answer in the app journal; it
/// never throws and never waits long.
class TrackingWake {
  TrackingWake._();

  /// Test seam for the native call.
  @visibleForTesting
  static Future<String> Function() native = BackgroundLocator.ensureRunning;

  @visibleForTesting
  static bool? androidOverride;

  static bool get _android => androidOverride ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  /// Asks the native side to restart the tracking service if it is wanted and
  /// not running. Returns the native outcome (`running`, `restarted`, `refused`,
  /// `debounced`, `not_wanted`) or `unsupported`.
  static Future<String> fromPush({TrackingJournal? journal}) async {
    if (!_android) return 'unsupported';
    String result;
    try {
      result = await native().timeout(const Duration(seconds: 5));
    } catch (_) {
      result = 'unsupported';
    }
    try {
      // Journal only what mattered: a service that was already running is the normal case.
      if (result != 'running') (journal ?? TrackingJournal.instance).record('push_wake', 'result=$result');
    } catch (_) {}
    return result;
  }
}
