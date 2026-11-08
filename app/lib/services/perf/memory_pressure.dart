import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'perf_profile.dart';

/// Android `ComponentCallbacks2.onTrimMemory` levels we react to.
class TrimLevel {
  static const int runningModerate = 5;
  static const int runningLow = 10;
  static const int runningCritical = 15;
  static const int uiHidden = 20;
  static const int background = 40;
  static const int moderate = 60;
  static const int complete = 80;
}

typedef Trimmer = void Function(bool severe);

/// Frees memory when the system asks for it: Flutter's own
/// `didHaveMemoryPressure` (Android low-memory and iOS memory warning) and
/// Android's `onTrimMemory` forwarded by MainActivity.
///
/// Always done: clear the decoded-image cache. [severe] trimmers (map tiles,
/// caches that can reload lazily) are called too. Nothing here may lose data:
/// a trimmer only drops what can be loaded again.
class MemoryPressureGuard with WidgetsBindingObserver {
  MemoryPressureGuard._();

  static final MemoryPressureGuard instance = MemoryPressureGuard._();

  static const MethodChannel channel = MethodChannel('app.openfamily/device');

  final List<Trimmer> _trimmers = <Trimmer>[];
  bool _installed = false;

  /// How many times pressure was handled (diagnostics, tests).
  int handled = 0;

  void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler((MethodCall c) async {
      if (c.method == 'trim') {
        final Object? a = c.arguments;
        handleTrim(a is int ? a : TrimLevel.runningLow);
      }
      return null;
    });
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
  }

  /// Registers a function that frees reloadable memory.
  void addTrimmer(Trimmer t) {
    if (!_trimmers.contains(t)) _trimmers.add(t);
  }

  void removeTrimmer(Trimmer t) => _trimmers.remove(t);

  @override
  void didHaveMemoryPressure() => handle(severe: true);

  /// Reacts to an Android trim level. UI-hidden and background levels are not
  /// emergencies, but a hidden app should not hold the map's pictures.
  void handleTrim(int level) {
    if (level < TrimLevel.runningLow) return;
    // UI hidden: only the pictures go. Background and the legacy critical
    // levels: everything that reloads lazily (Android 14+ delivers only
    // UI_HIDDEN and BACKGROUND).
    handle(severe: level == TrimLevel.runningCritical || level >= TrimLevel.background);
  }

  void handle({required bool severe}) {
    handled++;
    final ImageCache cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    for (final Trimmer t in List<Trimmer>.of(_trimmers)) {
      try {
        t(severe);
      } catch (_) {}
    }
  }

  /// The profile may shrink the image cache back to its tier limits.
  void reapplyProfile() => PerfProfile.current.applyToImageCache();
}
