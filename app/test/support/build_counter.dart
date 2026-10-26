import 'package:flutter/widgets.dart';

/// Counts element rebuilds by widget runtime type via the framework's own
/// `debugOnRebuildDirtyWidget` hook, so the same measurement works on code
/// that has no instrumentation of its own (used for before/after numbers).
class BuildCounter {
  final Map<String, int> counts = <String, int>{};

  void start() {
    debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
      final String name = e.widget.runtimeType.toString();
      counts[name] = (counts[name] ?? 0) + 1;
    };
  }

  void stop() => debugOnRebuildDirtyWidget = null;

  void reset() => counts.clear();

  int of(String type) => counts[type] ?? 0;

  /// Total rebuilds of all the given types.
  int sum(Iterable<String> types) => types.fold(0, (int a, String t) => a + of(t));
}
