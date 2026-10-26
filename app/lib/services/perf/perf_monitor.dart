import 'dart:io' show File, Platform;
import 'dart:ui' show FlutterView, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// On-device performance instrumentation (see docs/performance.md).
///
/// Design constraints, in order:
///  * negligible overhead: the always-on part is one [FrameTiming] callback
///    that increments a few integers and a fixed histogram per frame;
///  * nothing is stored on disk or sent anywhere: everything lives in memory
///    and disappears with the process;
///  * no personal data: HTTP entries carry only `METHOD /normalised/path`
///    (ids and tokens replaced by `:id`, no query, no body, no coordinates).
///
/// Detailed recording (rebuild counters, HTTP ring buffer, WebSocket
/// counters) is OFF until the hidden Performance screen switches it on.
class PerfMonitor {
  PerfMonitor._();

  static final PerfMonitor instance = PerfMonitor._();

  /// A private instance for unit tests.
  @visibleForTesting
  PerfMonitor.forTest();

  // --- recording switch --------------------------------------------------

  /// Whether the detailed (rebuilds / HTTP / WebSocket) recorders are on.
  bool recording = false;

  // --- frame summary (always on) ----------------------------------------

  static const int _bucketCount = 400; // 0.25 ms buckets up to 100 ms
  static const double _bucketMs = 0.25;
  final List<int> _buildHist = List<int>.filled(_bucketCount + 1, 0);
  final List<int> _rasterHist = List<int>.filled(_bucketCount + 1, 0);
  int frames = 0;
  int jankyFrames = 0;
  double _lastRefreshHz = 60;

  /// Slowest frames seen, worst first (at most [slowestKept]).
  static const int slowestKept = 10;
  final List<SlowFrame> slowest = <SlowFrame>[];

  /// Name of the screen that was visible; maintained by [PerfRouteObserver]
  /// and the app shell (tab name).
  String currentRoute = 'startup';

  /// Selected app-shell tab name; frames on the shell are attributed to
  /// `AppShell:<tab>` so the four tabs can be told apart.
  String shellTab = 'location';

  /// Called by the app shell when the visible tab changes.
  void setShellTab(String tab) {
    shellTab = tab;
    if (currentRoute.startsWith('AppShell')) currentRoute = 'AppShell:$tab';
  }

  /// Applies a resolved page-type name to [currentRoute].
  void setPage(String page) {
    currentRoute = page == 'AppShell' ? 'AppShell:$shellTab' : page;
  }

  bool _attached = false;

  /// Starts listening to frame timings. Idempotent.
  void attach() {
    if (_attached) return;
    _attached = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    _lastRefreshHz = _displayRefreshRate() ?? _lastRefreshHz;
    for (final FrameTiming t in timings) {
      addFrame(
        buildMicros: t.buildDuration.inMicroseconds,
        rasterMicros: t.rasterDuration.inMicroseconds,
        refreshHz: _lastRefreshHz,
      );
    }
  }

  double? _displayRefreshRate() {
    try {
      final Iterable<FlutterView> views =
          WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return null;
      final double hz = views.first.display.refreshRate;
      return hz > 0 ? hz : null;
    } catch (_) {
      return null;
    }
  }

  /// Records one frame. Public so tests can feed synthetic timings.
  void addFrame({
    required int buildMicros,
    required int rasterMicros,
    double refreshHz = 60,
  }) {
    frames++;
    _buildHist[_bucketOf(buildMicros)]++;
    _rasterHist[_bucketOf(rasterMicros)]++;
    final double budgetMs = 1000 / refreshHz;
    final double worstMs =
        (buildMicros > rasterMicros ? buildMicros : rasterMicros) / 1000;
    if (worstMs > budgetMs) jankyFrames++;
    refreshHzSeen = refreshHz;
    if (slowest.length < slowestKept || worstMs > slowest.last.worstMs) {
      slowest.add(SlowFrame(
        buildMs: buildMicros / 1000,
        rasterMs: rasterMicros / 1000,
        route: currentRoute,
      ));
      slowest.sort((SlowFrame a, SlowFrame b) => b.worstMs.compareTo(a.worstMs));
      if (slowest.length > slowestKept) slowest.removeLast();
    }
  }

  /// Last display refresh rate used for the jank budget.
  double refreshHzSeen = 60;

  int _bucketOf(int micros) {
    final int b = (micros / 1000 / _bucketMs).floor();
    return b >= _bucketCount ? _bucketCount : (b < 0 ? 0 : b);
  }

  /// Percentile (0..100) of frame build time in milliseconds.
  double buildPercentileMs(double p) => _percentile(_buildHist, p);

  /// Percentile (0..100) of frame raster time in milliseconds.
  double rasterPercentileMs(double p) => _percentile(_rasterHist, p);

  double _percentile(List<int> hist, double p) {
    int total = 0;
    for (final int c in hist) {
      total += c;
    }
    if (total == 0) return 0;
    final int target = (total * p / 100).ceil().clamp(1, total);
    int seen = 0;
    for (int i = 0; i < hist.length; i++) {
      seen += hist[i];
      if (seen >= target) return (i + 1) * _bucketMs; // bucket upper edge
    }
    return _bucketCount * _bucketMs;
  }

  /// Percentage (0..100) of frames over the refresh-rate budget.
  double get jankPercent => frames == 0 ? 0 : 100 * jankyFrames / frames;

  double get budgetMs => 1000 / refreshHzSeen;

  // --- startup -----------------------------------------------------------

  /// Milliseconds the process had already been alive when [main] started
  /// (engine + Dart VM boot). Null when it cannot be determined.
  int? processAgeAtMainMs;
  DateTime? _mainStart;
  int? firstFrameFromMainMs;
  final List<StartupStep> startupSteps = <StartupStep>[];

  /// Total process start to first frame, when known.
  int? get startupMs {
    final int? ff = firstFrameFromMainMs;
    if (ff == null) return null;
    return (processAgeAtMainMs ?? 0) + ff;
  }

  /// Called first thing in main().
  void markMainStart() {
    _mainStart = DateTime.now();
    processAgeAtMainMs = readProcessAgeMs();
  }

  /// Registers a one-shot first-frame callback.
  void watchFirstFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final DateTime? s = _mainStart;
      if (s != null && firstFrameFromMainMs == null) {
        firstFrameFromMainMs = DateTime.now().difference(s).inMilliseconds;
      }
    });
  }

  /// Times a startup step (always on; a handful per launch).
  Future<T> timeStep<T>(String name, Future<T> Function() body) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      addStartupStep(name, sw.elapsedMilliseconds);
    }
  }

  void addStartupStep(String name, int ms) {
    final DateTime? s = _mainStart;
    startupSteps.add(StartupStep(
      name,
      ms,
      s == null ? 0 : DateTime.now().difference(s).inMilliseconds,
    ));
  }

  /// Process age from `/proc/self/stat` (Linux/Android). Pure parse helper is
  /// [processAgeFromProc]; this one does the IO and never throws.
  static int? readProcessAgeMs() {
    try {
      if (kIsWeb || !(Platform.isAndroid || Platform.isLinux)) return null;
      final String stat = File('/proc/self/stat').readAsStringSync();
      final String uptime = File('/proc/uptime').readAsStringSync();
      return processAgeFromProc(stat, uptime);
    } catch (_) {
      return null;
    }
  }

  /// Process age in ms from the text of `/proc/self/stat` and `/proc/uptime`
  /// (start time is field 22, in clock ticks of 1/100 s on Android/Linux).
  @visibleForTesting
  static int? processAgeFromProc(String stat, String uptime,
      {int ticksPerSecond = 100}) {
    final int close = stat.lastIndexOf(')');
    if (close < 0) return null;
    final List<String> rest = stat.substring(close + 2).split(' ');
    // After the ")" the fields start at number 3 (state), so field 22 is
    // index 19.
    if (rest.length < 20) return null;
    final int? startTicks = int.tryParse(rest[19]);
    final double? up = double.tryParse(uptime.split(' ').first);
    if (startTicks == null || up == null) return null;
    final double age = up - startTicks / ticksPerSecond;
    if (age < 0 || age > 3600) return null;
    return (age * 1000).round();
  }

  // --- rebuild counters (recording only) ---------------------------------

  final Map<String, int> rebuilds = <String, int>{};

  /// Counts a build of the screen/widget [name]. One bool check when off.
  void countBuild(String name) {
    if (!recording) return;
    rebuilds[name] = (rebuilds[name] ?? 0) + 1;
  }

  // --- location reporting cadence (always on, tiny) ----------------------

  /// Label of the active location cadence profile (e.g. `driving`,
  /// `stationary`, `walking+lowbat`); set by the foreground reporter.
  String cadenceProfile = 'n/a';

  final Map<int, int> _fixMinutes = <int, int>{};
  int fixesSent = 0;

  /// One location fix was POSTed successfully.
  void recordFixSent() {
    fixesSent++;
    final int idx = clock().millisecondsSinceEpoch ~/ 60000;
    _fixMinutes[idx] = (_fixMinutes[idx] ?? 0) + 1;
    if (_fixMinutes.length > 30) {
      final List<int> keys = _fixMinutes.keys.toList()..sort();
      for (final int k in keys.take(_fixMinutes.length - 30)) {
        _fixMinutes.remove(k);
      }
    }
  }

  /// Fixes sent during the last full minute (0 when none).
  int get fixesLastMinute {
    final int idx = clock().millisecondsSinceEpoch ~/ 60000;
    return _fixMinutes[idx - 1] ?? 0;
  }

  /// Fixes sent in the current (partial) minute.
  int get fixesThisMinute {
    final int idx = clock().millisecondsSinceEpoch ~/ 60000;
    return _fixMinutes[idx] ?? 0;
  }

  // --- WebSocket (recording only) ----------------------------------------

  int wsReceived = 0;
  int wsApplied = 0;
  int wsUiUpdates = 0;
  final Map<int, _Minute> _wsMinutes = <int, _Minute>{};
  DateTime Function() clock = DateTime.now;

  /// A frame arrived. [applied] = it changed the roster / state.
  void recordWsFrame({required bool applied}) {
    if (!recording) return;
    wsReceived++;
    final _Minute m = _minute();
    m.received++;
    if (applied) {
      wsApplied++;
      m.applied++;
    }
  }

  /// The UI was told about a roster change (after coalescing).
  void recordWsUiUpdate() {
    if (!recording) return;
    wsUiUpdates++;
    _minute().ui++;
  }

  _Minute _minute() {
    final int idx = clock().millisecondsSinceEpoch ~/ 60000;
    final _Minute m = _wsMinutes.putIfAbsent(idx, _Minute.new);
    if (_wsMinutes.length > 30) {
      final List<int> keys = _wsMinutes.keys.toList()..sort();
      for (final int k in keys.take(_wsMinutes.length - 30)) {
        _wsMinutes.remove(k);
      }
    }
    return m;
  }

  /// Average frames per minute over the minutes that saw any traffic.
  ({double received, double applied, double ui}) get wsPerMinute {
    if (_wsMinutes.isEmpty) return (received: 0, applied: 0, ui: 0);
    int r = 0, a = 0, u = 0;
    for (final _Minute m in _wsMinutes.values) {
      r += m.received;
      a += m.applied;
      u += m.ui;
    }
    final int n = _wsMinutes.length;
    return (received: r / n, applied: a / n, ui: u / n);
  }

  // --- HTTP (recording only) ---------------------------------------------

  static const int httpRingSize = 400;
  final List<HttpSample> _http = <HttpSample>[];

  /// Records one request. [path] must already be the raw path; it is
  /// normalised here and the query string is dropped.
  void recordHttp(String method, String path, int ms, int status) {
    if (!recording) return;
    if (_http.length >= httpRingSize) _http.removeAt(0);
    _http.add(HttpSample(endpointLabel(method, path), ms, status));
  }

  List<HttpSample> get httpSamples => List<HttpSample>.unmodifiable(_http);

  /// Per-endpoint aggregates, busiest first.
  List<EndpointStats> endpointStats() {
    final Map<String, List<HttpSample>> by = <String, List<HttpSample>>{};
    for (final HttpSample s in _http) {
      (by[s.endpoint] ??= <HttpSample>[]).add(s);
    }
    final List<EndpointStats> out = <EndpointStats>[];
    by.forEach((String k, List<HttpSample> v) {
      final List<int> ms = v.map((HttpSample s) => s.ms).toList()..sort();
      out.add(EndpointStats(
        endpoint: k,
        count: v.length,
        errors: v.where((HttpSample s) => s.status == 0 || s.status >= 400).length,
        p50: ms[(ms.length - 1) ~/ 2],
        p90: ms[((ms.length - 1) * 0.9).round()],
        max: ms.last,
      ));
    });
    out.sort((EndpointStats a, EndpointStats b) => b.count.compareTo(a.count));
    return out;
  }

  static final RegExp _plainSegment = RegExp(r'^[a-z][a-z_-]{0,23}$');

  /// `GET /trips/:id/events` from `GET /trips/3f2a.../events?x=1`. Only plain
  /// lower-case words survive; anything else (uuids, codes, tokens) becomes
  /// `:id`, and the query string is dropped entirely.
  @visibleForTesting
  static String endpointLabel(String method, String path) {
    final int q = path.indexOf('?');
    final String p = q < 0 ? path : path.substring(0, q);
    final List<String> parts = p
        .split('/')
        .where((String s) => s.isNotEmpty)
        .map((String s) => _plainSegment.hasMatch(s) ? s : ':id')
        .toList();
    return '$method /${parts.join('/')}';
  }

  // --- report ------------------------------------------------------------

  /// Clears every counter (does not change [recording]).
  void reset() {
    for (final List<int> h in <List<int>>[_buildHist, _rasterHist]) {
      h.fillRange(0, h.length, 0);
    }
    frames = 0;
    jankyFrames = 0;
    slowest.clear();
    rebuilds.clear();
    wsReceived = 0;
    wsApplied = 0;
    wsUiUpdates = 0;
    _wsMinutes.clear();
    _fixMinutes.clear();
    fixesSent = 0;
    _http.clear();
  }

  /// Compact plain-text report for pasting to the developer.
  String buildReport({String? device}) {
    final StringBuffer b = StringBuffer();
    String f(double v) => v.toStringAsFixed(1);
    b.writeln('OpenFamily performance report');
    if (device != null) b.writeln('device: $device');
    b.writeln('recording: ${recording ? 'on' : 'off'}');
    final int? su = startupMs;
    b.writeln('startup: ${su == null ? 'n/a' : '$su ms'}'
        ' (process age at main ${processAgeAtMainMs ?? 'n/a'} ms,'
        ' main to first frame ${firstFrameFromMainMs ?? 'n/a'} ms)');
    for (final StartupStep s in startupSteps) {
      b.writeln('  step ${s.name}: ${s.ms} ms (at +${s.atMs} ms)');
    }
    b.writeln('frames: $frames, refresh ${refreshHzSeen.toStringAsFixed(0)} Hz,'
        ' budget ${f(budgetMs)} ms');
    b.writeln('build ms p50/p90/p99: ${f(buildPercentileMs(50))}'
        ' / ${f(buildPercentileMs(90))} / ${f(buildPercentileMs(99))}');
    b.writeln('raster ms p50/p90/p99: ${f(rasterPercentileMs(50))}'
        ' / ${f(rasterPercentileMs(90))} / ${f(rasterPercentileMs(99))}');
    b.writeln('janky frames: $jankyFrames (${f(jankPercent)}%)');
    b.writeln('slowest frames (build/raster ms, screen):');
    for (final SlowFrame s in slowest) {
      b.writeln('  ${f(s.buildMs)} / ${f(s.rasterMs)}  ${s.route}');
    }
    if (rebuilds.isNotEmpty) {
      b.writeln('rebuilds:');
      final List<MapEntry<String, int>> e = rebuilds.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final MapEntry<String, int> x in e) {
        b.writeln('  ${x.key}: ${x.value}');
      }
    }
    final pm = wsPerMinute;
    b.writeln('websocket: received $wsReceived, applied $wsApplied,'
        ' ui updates $wsUiUpdates'
        ' (per minute ${f(pm.received)} / ${f(pm.applied)} / ${f(pm.ui)})');
    b.writeln('location reporting: profile $cadenceProfile,'
        ' fixes sent $fixesSent (this minute $fixesThisMinute,'
        ' last minute $fixesLastMinute)');
    final List<EndpointStats> http = endpointStats();
    b.writeln('http: ${_http.length} requests');
    for (final EndpointStats s in http) {
      b.writeln('  ${s.endpoint}  n=${s.count} err=${s.errors}'
          ' p50=${s.p50} p90=${s.p90} max=${s.max} ms');
    }
    return b.toString();
  }
}

class _Minute {
  int received = 0;
  int applied = 0;
  int ui = 0;
}

class SlowFrame {
  const SlowFrame({
    required this.buildMs,
    required this.rasterMs,
    required this.route,
  });
  final double buildMs;
  final double rasterMs;
  final String route;
  double get worstMs => buildMs > rasterMs ? buildMs : rasterMs;
}

class StartupStep {
  const StartupStep(this.name, this.ms, this.atMs);
  final String name;
  final int ms;

  /// Milliseconds since main() when the step finished.
  final int atMs;
}

class HttpSample {
  const HttpSample(this.endpoint, this.ms, this.status);
  final String endpoint;
  final int ms;
  final int status;
}

class EndpointStats {
  const EndpointStats({
    required this.endpoint,
    required this.count,
    required this.errors,
    required this.p50,
    required this.p90,
    required this.max,
  });
  final String endpoint;
  final int count;
  final int errors;
  final int p50;
  final int p90;
  final int max;
}

/// Tracks the visible route so slow frames can be attributed to a screen.
class PerfRouteObserver extends NavigatorObserver {
  PerfRouteObserver([PerfMonitor? monitor])
      : _monitor = monitor ?? PerfMonitor.instance;

  final PerfMonitor _monitor;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _set(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _set(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _set(previousRoute);
  }

  void _set(Route<dynamic> route) {
    final String? named = route.settings.name;
    if (named != null && named.isNotEmpty && named != '/') {
      _monitor.currentRoute = named;
      return;
    }
    _monitor.currentRoute = route.runtimeType.toString();
    // Resolve the page widget's type once the route has built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? page = _pageTypeOf(route);
      if (page != null && route.isCurrent) _monitor.setPage(page);
    });
  }

  static String? _pageTypeOf(Route<dynamic> route) {
    final BuildContext? ctx = route is ModalRoute ? route.subtreeContext : null;
    if (ctx == null) return null;
    String? found;
    int depth = 0;
    void visit(Element e) {
      if (found != null || depth > 10) return;
      final Widget w = e.widget;
      if ((w is StatelessWidget || w is StatefulWidget) &&
          w.runtimeType != Builder &&
          !w.runtimeType.toString().startsWith('_')) {
        found = w.runtimeType.toString();
        return;
      }
      depth++;
      e.visitChildren(visit);
    }

    (ctx as Element).visitChildren(visit);
    return found;
  }
}

/// Counts how often [child]'s position is rebuilt by its parent. A no-op
/// wrapper unless recording is on.
class RebuildProbe extends StatelessWidget {
  const RebuildProbe({super.key, required this.name, required this.child});

  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    PerfMonitor.instance.countBuild(name);
    return child;
  }
}
