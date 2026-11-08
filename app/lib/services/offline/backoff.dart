import 'dart:math';

/// Exponential backoff with jitter for reconnect and probe loops: no tight
/// retry loops while a server is down, and a whole family's phones do not all
/// come back on the same second when it returns.
///
/// Delay for attempt n is `min(max, base * 2^n)` scaled by a random factor in
/// [0.5, 1.0] ("equal jitter"), so it never collapses to zero.
class Backoff {
  Backoff({
    this.base = const Duration(seconds: 3),
    this.max = const Duration(minutes: 5),
    Random? random,
  }) : _rng = random ?? Random();

  final Duration base;
  final Duration max;
  final Random _rng;
  int _attempt = 0;

  /// How many delays were handed out since the last [reset].
  int get attempt => _attempt;

  Duration next() {
    final int shift = _attempt > 20 ? 20 : _attempt;
    _attempt++;
    final int raw = base.inMilliseconds * (1 << shift);
    final int capped = raw > max.inMilliseconds || raw <= 0 ? max.inMilliseconds : raw;
    final double factor = 0.5 + _rng.nextDouble() * 0.5;
    return Duration(milliseconds: (capped * factor).round());
  }

  void reset() => _attempt = 0;
}
