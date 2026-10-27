import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/perf/perf_monitor.dart';
import '../services/session_diary.dart';
import '../theme/app_theme.dart';

/// Hidden developer screen (Settings > tap the version row 7 times).
///
/// Shows the numbers collected by [PerfMonitor] and copies a compact text
/// report for the owner to paste to the developer. Nothing here is stored on
/// disk or sent to a server.
class PerformanceScreen extends StatefulWidget {
  const PerformanceScreen({super.key, PerfMonitor? monitor})
      : _monitor = monitor;

  final PerfMonitor? _monitor;

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> {
  late final PerfMonitor _m = widget._monitor ?? PerfMonitor.instance;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Refresh once a second, only while this screen exists.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final String text =
        '${_m.buildReport()}\n${await SessionDiary.instance.render()}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Performance report copied')),
    );
  }

  String _f(double v) => v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final pm = _m.wsPerMinute;
    final int? startup = _m.startupMs;

    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(0, AppSpace.lg, 0, AppSpace.xs),
          child: Text(t, style: tt.titleSmall),
        );
    Widget line(String t) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(t, style: tt.bodyMedium?.copyWith(fontFeatures: const [
            FontFeature.tabularFigures(),
          ])),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Performance')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: <Widget>[
            Text(
              'Numbers stay in memory on this phone. Nothing is saved or sent.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Record details'),
              subtitle: const Text(
                  'Rebuilds, requests and WebSocket counts. Frame timing is '
                  'always summarised.'),
              value: _m.recording,
              onChanged: (bool v) => setState(() => _m.recording = v),
            ),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy report'),
                ),
                const SizedBox(width: AppSpace.md),
                OutlinedButton(
                  onPressed: () => setState(_m.reset),
                  child: const Text('Reset'),
                ),
              ],
            ),
            head('Startup'),
            line(startup == null
                ? 'Process start to first frame: n/a'
                : 'Process start to first frame: $startup ms'),
            for (final StartupStep s in _m.startupSteps)
              line('  ${s.name}: ${s.ms} ms'),
            head('Frames'),
            line('${_m.frames} frames at ${_m.refreshHzSeen.toStringAsFixed(0)}'
                ' Hz (budget ${_f(_m.budgetMs)} ms)'),
            line('Build p50/p90/p99: ${_f(_m.buildPercentileMs(50))} / '
                '${_f(_m.buildPercentileMs(90))} / '
                '${_f(_m.buildPercentileMs(99))} ms'),
            line('Raster p50/p90/p99: ${_f(_m.rasterPercentileMs(50))} / '
                '${_f(_m.rasterPercentileMs(90))} / '
                '${_f(_m.rasterPercentileMs(99))} ms'),
            line('Janky: ${_m.jankyFrames} (${_f(_m.jankPercent)}%)'),
            head('Slowest frames (build / raster, screen)'),
            if (_m.slowest.isEmpty) line('none yet'),
            for (final SlowFrame s in _m.slowest)
              line('${_f(s.buildMs)} / ${_f(s.rasterMs)} ms  ${s.route}'),
            head('Rebuilds'),
            if (!_m.recording)
              line('Turn on Record details.')
            else if (_m.rebuilds.isEmpty)
              line('none yet'),
            for (final MapEntry<String, int> e in (_m.rebuilds.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value))))
              line('${e.key}: ${e.value}'),
            head('WebSocket'),
            line('Received ${_m.wsReceived}, applied ${_m.wsApplied}, '
                'UI updates ${_m.wsUiUpdates}'),
            line('Per minute: ${_f(pm.received)} received, '
                '${_f(pm.applied)} applied, ${_f(pm.ui)} UI'),
            head('HTTP requests'),
            if (_m.endpointStats().isEmpty) line('none yet'),
            for (final EndpointStats s in _m.endpointStats())
              line('${s.endpoint}  n=${s.count} err=${s.errors} '
                  'p50=${s.p50} p90=${s.p90} max=${s.max} ms'),
          ],
        ),
      ),
    );
  }
}
