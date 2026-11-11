import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api_client.dart';
import '../services/background_location_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/diagnostics/diag_model.dart';
import '../services/diagnostics/diagnostics_probe.dart';
import '../services/diagnostics/diagnostics_reporter.dart';
import '../services/offline/offline_sync.dart';
import '../services/location_sharing_service.dart';
import '../services/permission_service.dart';
import '../services/storage_event_log.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_keys_screen.dart';
import 'notification_settings_screen.dart';
import 'self_test_screen.dart';
import 'server_config_screen.dart';

/// "Why isn't my phone reporting?" Runs every check on the phone, explains the
/// result in plain language and offers a one-tap fix. The copied report holds
/// no locations and no tokens.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, this.collect});

  /// Test seam: supplies facts instead of probing the phone.
  final Future<DiagFacts> Function()? collect;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> with WidgetsBindingObserver {
  DiagFacts? _facts;
  List<DiagCheck> _checks = const <DiagCheck>[];
  bool _busy = true;

  /// Sign-in and key storage events (reason codes only), newest last.
  List<String> _storageEvents = const <String>[];

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

  /// Coming back from a system settings page: re-check so the fix shows up.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) unawaited(_run());
  }

  Future<void> _run() async {
    setState(() => _busy = true);
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
        facts = await DiagnosticsProbe.collect(version: PackageVersion(version));
        // Share the phone-side state with the server for the admin fleet page.
        unawaited(DiagnosticsReporter.report(facts, force: true));
      }
    } catch (_) {
      facts = DiagFacts(now: DateTime.now().toUtc());
    }
    // The test seam supplies facts only; the event log is read from the phone.
    final List<String> events = widget.collect != null ? const <String>[] : await StorageEventLog.instance.events();
    if (!mounted) return;
    setState(() {
      _storageEvents = events;
      _facts = facts;
      _checks = evaluateDiagnostics(facts);
      _busy = false;
    });
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  Future<void> _fix(DiagFixKind kind) async {
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
      case DiagFixKind.openServerSettings:
        _push(const ServerConfigScreen(allowCancel: true));
      case DiagFixKind.signIn:
        ApiClient.onSessionExpired?.call();
      case DiagFixKind.sendQueue:
        setState(() => _busy = true);
        await OfflineSync.flushAll();
        await _run();
      case DiagFixKind.openPushSettings:
        _push(const NotificationSettingsScreen());
      case DiagFixKind.openEncryption:
        _push(const EncryptionKeysScreen());
      case DiagFixKind.runSelfTest:
        _push(const SelfTestScreen());
      case DiagFixKind.startTracking:
        await LocationSharingService.setEnabled(true);
        if (!kIsWeb) {
          try {
            await BackgroundLocationService.start();
          } catch (_) {}
        }
        await _run();
    }
  }

  Future<void> _copy() async {
    final DiagFacts? f = _facts;
    if (f == null) return;
    final String storage = widget.collect != null ? '' : await StorageEventLog.instance.render();
    await Clipboard.setData(ClipboardData(text: buildDiagnosticReport(f, _checks, storageEvents: storage)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied. The report has no locations or tokens.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DiagStatus overall = overallStatus(_checks);
    final int bad = _checks.where((DiagCheck c) => c.status == DiagStatus.fail).length;
    final int warn = _checks.where((DiagCheck c) => c.status == DiagStatus.warn).length;
    return DsPage(
      title: 'Diagnostics',
      actions: <Widget>[
        DsPillButton(label: 'Copy diagnostic report', icon: Icons.copy_outlined, style: DsPillStyle.tonal, onPressed: _facts == null ? null : _copy),
        DsPillButton(label: 'Run again', icon: Icons.refresh, onPressed: _busy ? null : _run),
      ],
      children: <Widget>[
        if (_busy && _facts == null)
          const Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...<Widget>[
          _Summary(status: overall, failures: bad, warnings: warn, busy: _busy),
          for (final DiagCheck c in _checks) _CheckCard(check: c, onFix: _fix),
          DsListRow(
            leading: DsListRow.iconTile(context, Icons.science_outlined),
            title: 'Self-test',
            subtitle: 'Send a test position and alert',
            info: 'Uploads a test position, checks encryption and sends a test alert, so you can see the whole path works.',
            chevron: true,
            onTap: () => _push(const SelfTestScreen()),
          ),
          _StorageEvents(events: _storageEvents),
          const Padding(
            padding: EdgeInsets.all(AppSpace.lg),
            child: Text(
              'These checks run on this phone. Only a real walk with the screen off proves tracking works.',
              style: AppType.secondary,
            ),
          ),
          // Room for the pinned buttons so the last item is never covered.
          const SizedBox(key: Key('diag-bottom-pad'), height: AppSpace.xxl),
        ],
      ],
    );
  }
}

Color statusColor(DiagStatus s) {
  switch (s) {
    case DiagStatus.pass:
      return AppColors.statusGreen;
    case DiagStatus.warn:
      return AppColors.statusOrange;
    case DiagStatus.fail:
      return AppColors.statusRed;
    case DiagStatus.info:
      return AppColors.statusGrey;
  }
}

IconData statusIcon(DiagStatus s) {
  switch (s) {
    case DiagStatus.pass:
      return Icons.check_circle;
    case DiagStatus.warn:
      return Icons.error_outline;
    case DiagStatus.fail:
      return Icons.cancel;
    case DiagStatus.info:
      return Icons.info_outline;
  }
}

String statusLabel(DiagStatus s) {
  switch (s) {
    case DiagStatus.pass:
      return 'OK';
    case DiagStatus.warn:
      return 'Check';
    case DiagStatus.fail:
      return 'Problem';
    case DiagStatus.info:
      return 'Info';
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.status, required this.failures, required this.warnings, required this.busy});
  final DiagStatus status;
  final int failures;
  final int warnings;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final String headline = switch (status) {
      DiagStatus.pass => 'Everything looks right',
      DiagStatus.warn => 'A few things to check',
      _ => 'Your phone is probably not reporting',
    };
    final String sub = failures + warnings == 0
        ? 'Every check passed.'
        : '${failures == 0 ? '' : '$failures problem${failures == 1 ? '' : 's'}'}'
            '${failures > 0 && warnings > 0 ? ' and ' : ''}'
            '${warnings == 0 ? '' : '$warnings to check'}. Fix the first one and run again.';
    final Color c = statusColor(status);
    return Semantics(
      container: true,
      label: '$headline. $sub',
      child: Container(
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

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.check, required this.onFix});
  final DiagCheck check;
  final Future<void> Function(DiagFixKind) onFix;

  @override
  Widget build(BuildContext context) {
    final Color c = statusColor(check.status);
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
              Icon(statusIcon(check.status), color: c, size: 22),
              const SizedBox(width: AppSpace.sm),
              Expanded(child: Text(check.title, style: AppType.headline)),
              DsStatusChip(label: statusLabel(check.status), color: c),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(check.detail),
          if (check.fix != null || check.secondaryFix != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: <Widget>[
                if (check.fix != null)
                  DsPillButton(label: check.fix!.label, style: DsPillStyle.tonal, onPressed: () => onFix(check.fix!.kind)),
                if (check.secondaryFix != null)
                  DsPillButton(label: check.secondaryFix!.label, style: DsPillStyle.outlined, onPressed: () => onFix(check.secondaryFix!.kind)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The sign-in and key storage event log (Diagnostics): every storage read or
/// decrypt failure, fallback, archive, migration and sign-out cause, as reason
/// codes. Collapsed by default; included in the copied report.
class _StorageEvents extends StatelessWidget {
  const _StorageEvents({required this.events});
  final List<String> events;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('diag-storage-events'),
        leading: DsListRow.iconTile(context, Icons.history),
        title: const Text('Sign-in and key storage', style: AppType.body),
        subtitle: Text(
          events.isEmpty ? 'No storage events recorded' : '${events.length} recent events (no secrets)',
          style: AppType.secondary,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (events.isEmpty) const Text('Nothing went wrong with stored sign-in or keys.', style: AppType.secondary),
          for (final String e in events.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(e, style: AppType.secondary.copyWith(fontFamily: 'monospace')),
            ),
        ],
      ),
    );
  }
}
