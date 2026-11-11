import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:geolocator/geolocator.dart';

import 'background_location_service.dart';
import 'diagnostics/tracking_journal.dart';
import 'diagnostics/tracking_stats.dart';
import 'location_sharing_service.dart';

/// What [TrackingResume.onResume] decided.
enum ResumeOutcome {
  /// Not an Android phone (the plugin's running state is only reliable there).
  unsupported,

  /// The user switched sharing off: nothing may run.
  sharingOff,

  /// "Allow all the time" is not granted: the service cannot be started.
  noPermission,

  /// Another resume check is still running.
  busy,

  /// The service was started a moment ago by someone else.
  startedRecently,

  /// The running state could not be read: nothing was started on a guess.
  unknown,

  /// The service is running: nothing to do.
  running,

  /// Tracking was wanted, the service was not running, and it was started.
  restarted,
}

/// When the app returns to the foreground, makes sure the background location
/// service is running if tracking is wanted.
///
/// Why: the service is only started when the map opens or sharing is switched
/// on. If Android ended it while the app was away (and did not bring it back),
/// nothing noticed until the user toggled sharing or restarted the app. The app
/// may start a foreground service while it is visible, so this is allowed here
/// and nowhere in the background.
///
/// This does not stop Android from killing the service; it only shortens the
/// time the phone stays silent after the person looks at it again.
class TrackingResume {
  TrackingResume._();

  static bool _busy = false;

  /// Starts the service when [LocationSharingService] says tracking is wanted, the permission is granted and the
  /// service is not running. Idempotent (one check at a time, no start while it already runs or was just started)
  /// and cheap (one permission read and one method-channel call). Never throws. The parameters are test seams.
  static Future<ResumeOutcome> onResume({
    bool? android,
    bool Function()? sharingOn,
    Future<String> Function()? permission,
    Future<bool> Function()? isRunning,
    Future<void> Function()? start,
    DateTime? Function()? lastStartAt,
    TrackingJournal? journal,
    DateTime Function()? clock,
  }) async {
    final bool isAndroid = android ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
    if (!isAndroid) return ResumeOutcome.unsupported;
    if (_busy) return ResumeOutcome.busy;
    _busy = true;
    try {
      final TrackingJournal j = journal ?? TrackingJournal.instance;
      final DateTime Function() now = clock ?? DateTime.now;
      String perm;
      try {
        perm = await (permission ?? _permission)();
      } catch (_) {
        perm = 'unknown';
      }
      await j.notePermission(perm);
      if (!(sharingOn ?? () => LocationSharingService.enabled.value)()) return ResumeOutcome.sharingOff;
      if (perm != 'always') return ResumeOutcome.noPermission;
      final DateTime? started = (lastStartAt ?? () => BackgroundLocationService.lastStartAt)();
      if (started != null && now().difference(started).abs() < const Duration(seconds: 20)) {
        return ResumeOutcome.startedRecently;
      }
      final bool running;
      try {
        running = await (isRunning ?? BackgroundLocationService.isRunning)();
      } catch (_) {
        return ResumeOutcome.unknown;
      }
      if (running) return ResumeOutcome.running;
      j.record('service_restarted_on_resume', 'was_running=false');
      await (start ?? BackgroundLocationService.start)();
      return ResumeOutcome.restarted;
    } catch (e) {
      TrackingStats.instance.noteError('resume_check', e);
      return ResumeOutcome.unknown;
    } finally {
      _busy = false;
    }
  }

  static Future<String> _permission() async {
    final LocationPermission p = await Geolocator.checkPermission();
    return switch (p) {
      LocationPermission.always => 'always',
      LocationPermission.whileInUse => 'while_in_use',
      LocationPermission.denied || LocationPermission.deniedForever => 'denied',
      LocationPermission.unableToDetermine => 'unknown',
    };
  }
}
