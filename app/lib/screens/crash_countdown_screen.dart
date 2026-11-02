import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/driving/crash_pending.dart';
import '../theme/app_theme.dart';

/// Full-screen "Are you OK?" prompt shown after a probable crash. Counts down
/// (30 s); "I'm OK" cancels, "I need help" sends right away, and when the
/// countdown ends the circle is alerted. After the alert went out a "False
/// alarm" button tells the circle so. Never contacts emergency services.
class CrashCountdownScreen extends StatefulWidget {
  const CrashCountdownScreen({
    super.key,
    this.send,
    this.markStatus,
    this.sendHelp,
    this.now,
    this.haptics = true,
  });

  /// Test seams. Defaults use the signed-in account session.
  final Future<String?> Function(CrashPending crash)? send;
  final Future<void> Function(String crashId, String status)? markStatus;
  final Future<void> Function(CrashPending crash)? sendHelp;
  final int Function()? now;
  final bool haptics;

  @override
  State<CrashCountdownScreen> createState() => _CrashCountdownScreenState();
}

class _CrashCountdownScreenState extends State<CrashCountdownScreen> {
  CrashPending? _crash;
  Timer? _timer;
  bool _sending = false;
  int _lastAttempt = 0;
  int _ticks = 0;
  String? _error;

  int get _now => (widget.now ?? () => DateTime.now().millisecondsSinceEpoch)();

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    final CrashPending? c = await CrashPendingStore.load();
    if (!mounted) return;
    if (c == null || c.cancelled) {
      _timer?.cancel();
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      return;
    }
    setState(() => _crash = c);
    _ticks++;
    final int now = _now;
    final CrashPhase phase = c.phase(now);
    if (phase == CrashPhase.counting && widget.haptics && _ticks.isEven) {
      HapticFeedback.heavyImpact();
      if (_ticks % 4 == 0) SystemSound.play(SystemSoundType.alert);
    }
    if (phase == CrashPhase.sending) await _deliver(c, now);
  }

  Future<void> _deliver(CrashPending c, int now) async {
    // The background service normally sends; this is the backstop when it
    // cannot (killed while the screen is open). The server de-duplicates on
    // the crash time, so both sending is harmless.
    if (_sending || now - _lastAttempt < 10000) return;
    _sending = true;
    _lastAttempt = now;
    try {
      final String? id = await (widget.send ?? _defaultSend)(c);
      if (id != null) await CrashPendingStore.markSent(id);
      if (mounted) setState(() => _error = null);
    } on SessionExpiredException {
      // Handled by the app's session gate.
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Couldn't reach the server. Retrying.");
      }
    } finally {
      _sending = false;
    }
  }

  static Future<String?> _defaultSend(CrashPending c) async {
    final dynamic r = await ApiClient.post('/crash-alerts', body: c.toRequestBody());
    return r is Map && r['id'] is String ? r['id'] as String : null;
  }

  Future<void> _ok() async {
    await CrashPendingStore.cancel();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _help() async {
    final CrashPending? c = await CrashPendingStore.requestHelp();
    if (c == null) return;
    try {
      // Goes through the normal help-alert pipeline too, so it shows in the
      // alerts history for the whole circle.
      final Future<void> Function(CrashPending) h =
          widget.sendHelp ?? _defaultHelp;
      await h(c);
    } catch (_) {}
    if (mounted) setState(() => _crash = c);
  }

  static Future<void> _defaultHelp(CrashPending c) async {
    await ApiClient.post('/alerts/help', body: <String, dynamic>{
      if (c.lat != null) 'lat': c.lat,
      if (c.lon != null) 'lon': c.lon,
      'note': 'Possible crash detected by their phone',
    });
  }

  Future<void> _mark(String status) async {
    final String? id = _crash?.sentId;
    if (id != null) {
      try {
        final Future<void> Function(String, String) m =
            widget.markStatus ?? _defaultMark;
        await m(id, status);
      } catch (_) {}
    }
    await CrashPendingStore.clear();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  static Future<void> _defaultMark(String id, String status) async {
    await ApiClient.post('/crashes/$id/status',
        body: <String, dynamic>{'status': status});
  }

  @override
  Widget build(BuildContext context) {
    final CrashPending? c = _crash;
    final CrashPhase phase = c?.phase(_now) ?? CrashPhase.counting;
    final bool sent = phase == CrashPhase.sent;
    final bool sending = phase == CrashPhase.sending;
    final int left = c?.secondsLeft(_now) ?? CrashPending.countdown.inSeconds;
    const Color fg = Colors.white;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: sent ? const Color(0xFF1F3A2E) : AppColors.sosRed,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(sent ? Icons.check_circle_outline : Icons.car_crash_outlined,
                    size: 72, color: fg),
                const SizedBox(height: AppSpace.lg),
                Text(
                  sent
                      ? 'Alert sent'
                      : sending
                          ? 'Alerting your circle'
                          : 'Are you OK?',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: fg, fontSize: 36, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  sent
                      ? 'Your circle was told about a possible crash. '
                          'Emergency services were NOT contacted; call your '
                          'local emergency number if you need them.'
                      : sending
                          ? 'Sending the alert now.'
                          : 'Your phone felt a hard impact and a sudden stop. '
                              'Your circle is alerted when the timer ends.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: fg, fontSize: 16),
                ),
                if (!sent && !sending) ...<Widget>[
                  const SizedBox(height: AppSpace.xl),
                  Semantics(
                    liveRegion: true,
                    label: '$left seconds left',
                    child: Text(
                      '$left',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: fg, fontSize: 96, fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: AppSpace.md),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: fg)),
                ],
                const SizedBox(height: AppSpace.xl),
                if (sent) ...<Widget>[
                  FilledButton(
                    key: const Key('crash-false-alarm'),
                    style: FilledButton.styleFrom(
                        backgroundColor: fg, foregroundColor: Colors.black),
                    onPressed: () => _mark('false_alarm'),
                    child: const Text('False alarm, I am fine'),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextButton(
                    key: const Key('crash-close'),
                    style: TextButton.styleFrom(foregroundColor: fg),
                    onPressed: () => _mark('ok'),
                    child: const Text('Close'),
                  ),
                ] else ...<Widget>[
                  FilledButton(
                    key: const Key('crash-ok'),
                    style: FilledButton.styleFrom(
                        backgroundColor: fg,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(64)),
                    onPressed: _ok,
                    child: const Text("I'm OK",
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: AppSpace.md),
                  OutlinedButton(
                    key: const Key('crash-help'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: fg,
                        side: const BorderSide(color: fg, width: 2),
                        minimumSize: const Size.fromHeight(56)),
                    onPressed: sending ? null : _help,
                    child: const Text('I need help',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
