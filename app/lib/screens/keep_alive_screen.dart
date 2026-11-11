import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/background_location_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/diagnostics/diag_model.dart';
import '../services/diagnostics/diagnostics_probe.dart';
import '../services/diagnostics/keep_alive.dart';
import '../services/location_sharing_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'diagnostics_screen.dart' show DiagCheckCard, statusColor, statusIcon;

/// "Keep tracking alive": the settings that decide whether Android lets Orbitly keep reporting with the screen off,
/// each with its live state and a one-tap fix. Re-checks every time the app comes back from a settings page.
///
/// Orbitly cannot make Android keep it alive; it can only be exempt wherever the user can allow that and say, live,
/// when something is not. This screen is that. It reads the same facts as Diagnostics ([evaluateKeepAlive]).
class KeepAliveScreen extends StatefulWidget {
  const KeepAliveScreen({super.key, this.collect, this.onFix});

  /// Test seam: supplies facts instead of probing the phone.
  final Future<DiagFacts> Function()? collect;

  /// Test seam: replaces the system calls a fix button makes.
  final Future<void> Function(DiagFixKind kind)? onFix;

  @override
  State<KeepAliveScreen> createState() => _KeepAliveScreenState();
}

class _KeepAliveScreenState extends State<KeepAliveScreen> with WidgetsBindingObserver {
  List<DiagCheck> _checks = const <DiagCheck>[];
  DiagFacts? _facts;
  bool _busy = true;
  bool _again = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from a system settings page: re-check so the change shows.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_run());
  }

  Future<void> _run() async {
    if (_busy && _facts != null) {
      // A check is running: run once more when it ends, so a change made meanwhile is not missed.
      _again = true;
      return;
    }
    if (mounted) setState(() => _busy = true);
    DiagFacts facts;
    try {
      if (widget.collect != null) {
        facts = await widget.collect!();
      } else {
        String version = '';
        try {
          final PackageInfo info = await PackageInfo.fromPlatform();
          version = '${info.version}+${info.buildNumber}';
        } catch (_) {}
        facts = await DiagnosticsProbe.collect(version: PackageVersion(version), light: true, withTracking: true);
      }
    } catch (_) {
      facts = DiagFacts(now: DateTime.now().toUtc());
    }
    if (!mounted) return;
    setState(() {
      _facts = facts;
      _checks = evaluateKeepAlive(facts);
      _busy = false;
    });
    if (_again) {
      _again = false;
      unawaited(_run());
    }
  }

  Future<void> _fix(DiagFixKind kind) async {
    if (widget.onFix != null) {
      await widget.onFix!(kind);
      return;
    }
    switch (kind) {
      case DiagFixKind.openAppSettings:
        await PermissionService.openSettings();
      case DiagFixKind.requestLocation:
        final PermissionState s = await PermissionService.request(OnboardingPermission.location);
        if (s == PermissionState.permanentlyDenied) await PermissionService.openSettings();
        await _run();
      case DiagFixKind.requestNotifications:
        final PermissionState s = await PermissionService.request(OnboardingPermission.notifications);
        if (s == PermissionState.permanentlyDenied) await PermissionService.openSettings();
        await _run();
      case DiagFixKind.batterySettings:
        await BatteryOptimizationService.openSettings();
      case DiagFixKind.oemAutostart:
        final String? opened = await DiagnosticsProbe.openOemSettings('autostart');
        if (opened == null) await BatteryOptimizationService.openSettings();
      case DiagFixKind.oemBattery:
        final String? opened = await DiagnosticsProbe.openOemSettings('battery');
        if (opened == null) await BatteryOptimizationService.openSettings();
      case DiagFixKind.startTracking:
        await LocationSharingService.setEnabled(true);
        if (!kIsWeb) {
          try {
            await BackgroundLocationService.start();
          } catch (_) {}
        }
        await _run();
      case DiagFixKind.openServerSettings:
      case DiagFixKind.signIn:
      case DiagFixKind.sendQueue:
      case DiagFixKind.openPushSettings:
      case DiagFixKind.openEncryption:
      case DiagFixKind.runSelfTest:
        // Not part of this checklist.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ({int fail, int warn}) n = keepAliveCounts(_checks);
    final bool android = _facts?.isAndroid ?? true;
    return DsPage(
      title: 'Keep tracking alive',
      actions: <Widget>[
        DsPillButton(label: 'Check again', icon: Icons.refresh, onPressed: _busy ? null : _run),
      ],
      children: <Widget>[
        if (_busy && _facts == null)
          const Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (!android)
          const Padding(
            key: Key('keep-alive-not-android'),
            padding: EdgeInsets.all(AppSpace.lg),
            child: Text('iPhones have no battery or sleep settings to change here. Allow location "Always" for '
                'Orbitly in the iPhone settings.'),
          )
        else ...<Widget>[
          _Headline(failures: n.fail, warnings: n.warn, busy: _busy),
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
            child: Text(
              'Android decides whether Orbitly may keep reporting when the app is closed. These are the settings '
              'you control. Orbitly also tries to restart itself, but Android only allows that when these are right.',
              style: AppType.secondary,
            ),
          ),
          for (final DiagCheck c in _checks) DiagCheckCard(check: c, onFix: _fix),
          const SizedBox(key: Key('keep-alive-bottom-pad'), height: AppSpace.xxl),
        ],
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.failures, required this.warnings, required this.busy});
  final int failures;
  final int warnings;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final DiagStatus status = failures > 0
        ? DiagStatus.fail
        : warnings > 0
            ? DiagStatus.warn
            : DiagStatus.pass;
    final String headline = switch (status) {
      DiagStatus.pass => 'Orbitly is set up to keep running',
      DiagStatus.warn => 'Almost: a few things to check',
      _ => 'Android may stop Orbitly when the app is closed',
    };
    final String sub = failures + warnings == 0
        ? 'Every setting you control is right.'
        : '${failures == 0 ? '' : '$failures to fix'}'
            '${failures > 0 && warnings > 0 ? ' and ' : ''}'
            '${warnings == 0 ? '' : '$warnings to check'}. Use the buttons below.';
    final Color c = statusColor(status);
    return Semantics(
      container: true,
      label: '$headline. $sub',
      child: Container(
        key: const Key('keep-alive-headline'),
        margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: <Widget>[
            busy
                ? const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3))
                : Icon(statusIcon(status), size: 32, color: c),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(headline, style: AppType.headline),
                  const SizedBox(height: 2),
                  Text(sub),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
