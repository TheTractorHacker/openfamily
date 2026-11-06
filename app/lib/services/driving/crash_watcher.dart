import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/crash_countdown_screen.dart';
import '../platform_features.dart';
import 'crash_pending.dart';
import 'driving_settings.dart';

/// UI-isolate side of crash detection: while the app is open, notices a
/// pending crash left by the background detector and shows the "Are you OK?"
/// screen. Also covers the notification tap, which just opens the app.
class CrashWatcher {
  CrashWatcher(this.context, {this.every = const Duration(seconds: 3)});

  /// A context under the app's [Navigator]; must stay mounted.
  final BuildContext Function() context;
  final Duration every;

  Timer? _timer;
  bool _open = false;

  void start() {
    if (!PlatformFeatures.drivingSensors) return; // crash detection is Android only
    _timer ??= Timer.periodic(every, (_) => unawaited(check()));
    unawaited(check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> check() async {
    if (_open) return;
    try {
      if (!await DrivingSettings.crashEnabled()) return;
      final CrashPending? c = await CrashPendingStore.load();
      if (c == null) return;
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (!c.isLive(now)) return;
      final BuildContext ctx = context();
      if (!ctx.mounted) return;
      _open = true;
      await Navigator.of(ctx).push<void>(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const CrashCountdownScreen(),
      ));
    } catch (_) {
      // Never break the shell.
    } finally {
      _open = false;
    }
  }
}
