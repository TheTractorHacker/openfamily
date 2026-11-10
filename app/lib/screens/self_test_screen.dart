import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/diagnostics/diag_model.dart';
import '../services/diagnostics/self_test.dart';
import '../services/e2ee/private_runtime.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'diagnostics_screen.dart' show statusColor, statusIcon, statusLabel;
import '../services/error_copy.dart';

/// Runs the automatic self-test and the background test. Be honest about
/// what it proves: see [SelfTest].
class SelfTestScreen extends StatefulWidget {
  const SelfTestScreen({super.key, this.test});

  /// Test seam.
  final SelfTest? test;

  @override
  State<SelfTestScreen> createState() => _SelfTestScreenState();
}

class _SelfTestScreenState extends State<SelfTestScreen> with WidgetsBindingObserver {
  final List<SelfTestResult> _results = <SelfTestResult>[];
  bool _running = false;

  // Background test: remember when the app left the foreground, then ask the
  // server whether it heard from this phone while the screen was off.
  static const Duration _bgWindow = Duration(minutes: 5);
  DateTime? _bgArmedAt;
  DateTime? _leftAt;
  String? _bgResult;
  DiagStatus _bgStatus = DiagStatus.info;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_bgArmedAt == null) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _leftAt ??= DateTime.now().toUtc();
    } else if (state == AppLifecycleState.resumed && _leftAt != null) {
      unawaited(_finishBackgroundTest());
    }
  }

  Future<void> _runAll() async {
    final SelfTest t = widget.test ?? SelfTest();
    setState(() {
      _running = true;
      _results.clear();
    });
    bool privateOnly = false;
    try {
      final UplinkMode mode = await PrivateRuntime.instance.uplinkMode();
      privateOnly = mode == UplinkMode.sealedOnly;
    } catch (_) {}
    final List<Future<SelfTestResult> Function()> steps = <Future<SelfTestResult> Function()>[
      t.keystoreRoundTrip,
      t.vaultRoundTrip,
      t.cryptoRoundTrip,
      () => t.uploadAndReadBack(privateOnly: privateOnly),
      t.notifications,
    ];
    for (final Future<SelfTestResult> Function() step in steps) {
      final SelfTestResult r = await step();
      if (!mounted) return;
      setState(() => _results.add(r));
    }
    if (mounted) setState(() => _running = false);
  }

  void _armBackground() {
    setState(() {
      _bgArmedAt = DateTime.now().toUtc();
      _leftAt = null;
      _bgResult = null;
    });
  }

  Future<void> _finishBackgroundTest() async {
    final DateTime? left = _leftAt;
    final DateTime? armed = _bgArmedAt;
    if (left == null || armed == null) return;
    final Duration away = DateTime.now().toUtc().difference(left);
    if (away < const Duration(minutes: 2)) {
      setState(() {
        _bgStatus = DiagStatus.info;
        _bgResult = 'You were away for only ${away.inSeconds} seconds. Stay away for at least ${_bgWindow.inMinutes} minutes '
            'with the screen locked, then come back.';
        _leftAt = null;
      });
      return;
    }
    try {
      final dynamic res = await ApiClient.get('/me/diagnostics');
      final DateTime? serverNow = res is Map<String, dynamic> ? DateTime.tryParse('${res['server_time']}')?.toUtc() : null;
      final DateTime? last = res is Map<String, dynamic> ? DateTime.tryParse('${res['last_report_at']}')?.toUtc() : null;
      if (serverNow == null || last == null) throw const FormatException();
      // Convert "when I left" onto the server clock: server_now - away.
      final DateTime leftOnServer = serverNow.subtract(away);
      final bool heard = last.isAfter(leftOnServer.add(const Duration(seconds: 20)));
      setState(() {
        _bgStatus = heard ? DiagStatus.pass : DiagStatus.fail;
        _bgResult = heard
            ? 'The server heard from this phone while the app was in the background (${away.inMinutes} minutes away). '
                'Background reporting works.'
            : 'You were away for ${away.inMinutes} minutes and the server heard nothing from this phone in that time. '
                'Run the diagnostics: battery limits or a missing "all the time" permission are the usual causes.';
        _leftAt = null;
        _bgArmedAt = null;
      });
    } catch (e) {
      setState(() {
        _bgStatus = DiagStatus.warn;
        _bgResult = actionFailedMessage(e, 'ask the server how it did');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'Self-test',
      actions: <Widget>[
        DsPillButton(label: _running ? 'Running...' : 'Run self-test', icon: Icons.play_arrow, onPressed: _running ? null : _runAll),
      ],
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: Text(
            'Checks encryption with this phone\'s real key store, uploads your current '
            'position once and reads the server\'s answer, and sends a test notification. '
            'It writes one normal location point, nothing else.',
          ),
        ),
        for (final SelfTestResult r in _results) _ResultRow(r),
        const DsSectionHeader('Background test'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Text(
            _bgArmedAt == null
                ? 'Proves the phone reports with the app closed. Tap Start, lock the phone, '
                    'put it in your pocket and walk around for ${_bgWindow.inMinutes} minutes, '
                    'then open Orbitly again.'
                : _leftAt == null
                    ? 'Armed. Now lock the phone and leave it for at least ${_bgWindow.inMinutes} minutes, then come back to this screen.'
                    : 'Waiting for you to come back...',
          ),
        ),
        if (_bgResult != null)
          _ResultRow(SelfTestResult('bg', 'Background reporting', _bgStatus, _bgResult!)),
        Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DsPillButton(
              label: _bgArmedAt == null ? 'Start background test' : 'Restart',
              style: DsPillStyle.tonal,
              onPressed: _armBackground,
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow(this.r);
  final SelfTestResult r;

  @override
  Widget build(BuildContext context) {
    final Color c = statusColor(r.status);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.xs),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border(left: BorderSide(color: c, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(statusIcon(r.status), color: c, size: 22),
              const SizedBox(width: AppSpace.sm),
              Expanded(child: Text(r.title, style: AppType.headline)),
              DsStatusChip(label: r.needsHuman ? 'Confirm' : statusLabel(r.status), color: c),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(r.detail),
        ],
      ),
    );
  }
}
