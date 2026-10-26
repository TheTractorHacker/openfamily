import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

String formatAlertTime(DateTime t, {DateTime? now}) {
  final DateTime n = now ?? DateTime.now();
  final Duration ago = n.difference(t);
  if (ago.inSeconds < 60) return 'just now';
  if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
  final String hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == n.year && t.month == n.month && t.day == n.day) {
    return 'today $hm';
  }
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hm';
}

/// Recipient-side alert screen: who sent what, and an idempotent
/// Acknowledge button. Opened from live alert frames, the history list, or
/// when the app resumes with an active alert from someone else.
class AlertReceivedScreen extends StatefulWidget {
  const AlertReceivedScreen({
    super.key,
    required this.alert,
    this.service = const AlertService(),
    this.dialer = const EmergencyDialer(),
    this.onOpenMap,
  });

  final AlertSummary alert;
  final AlertService service;
  final EmergencyDialer dialer;
  final VoidCallback? onOpenMap;

  @override
  State<AlertReceivedScreen> createState() => _AlertReceivedScreenState();
}

class _AlertReceivedScreenState extends State<AlertReceivedScreen> {
  bool _busy = false;
  DateTime? _ackedAt;
  String? _error;

  Future<void> _ack() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final DateTime? at = await widget.service.acknowledge(widget.alert.id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ackedAt = at ?? DateTime.now();
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = alertErrorMessage(e, action: 'acknowledge');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AlertSummary a = widget.alert;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color muted = cs.onSurfaceVariant;
    final bool urgent = a.kind == AlertKind.sos && a.isActive;
    final String headline = switch (a.kind) {
      AlertKind.sos => '${a.senderName} sent an SOS',
      AlertKind.help => '${a.senderName} asked for help',
      AlertKind.checkIn => '${a.senderName} checked in',
      AlertKind.unknown => 'Alert from ${a.senderName}',
    };
    return DsPage(
      title: alertKindLabel(a.kind),
      maxWidth: 560,
      actions: <Widget>[
        if (_ackedAt == null)
          KeyedSubtree(
            key: const ValueKey<String>('ack-button'),
            child: DsBusyButton(
              label: 'Acknowledge',
              icon: Icons.check,
              busy: _busy,
              onPressed: _busy ? null : _ack,
            ),
          ),
        if (widget.dialer.available)
          DsPillButton(
            label: 'Call emergency services',
            icon: Icons.call,
            style: urgent ? DsPillStyle.danger : DsPillStyle.outlined,
            onPressed: widget.dialer.dial,
          ),
        if (widget.onOpenMap != null)
          DsPillButton(
            label: 'Open the map',
            icon: Icons.map_outlined,
            style: DsPillStyle.tonal,
            onPressed: widget.onOpenMap,
          ),
      ],
      children: <Widget>[
        Semantics(
          header: true,
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                urgent ? Icons.warning_amber_rounded : Icons.notifications_none,
                size: 36,
                color: urgent
                    ? AppColors.sosRed
                    : BrandTheme.of(context).accentInk,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  headline,
                  style: AppType.title.copyWith(fontSize: 26),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          '${formatAlertTime(a.createdAt)} · ${a.isActive ? 'Active' : 'Resolved'}',
          style: AppType.body.copyWith(fontWeight: FontWeight.w500, color: muted),
        ),
        if (a.note.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpace.md),
          Text('"${a.note}"', style: AppType.headline),
        ],
        if (urgent) ...<Widget>[
          const SizedBox(height: AppSpace.lg),
          Container(
            padding: const EdgeInsets.all(AppSpace.lg),
            decoration: BoxDecoration(
              color: BrandTheme.of(context).sheet,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: cs.outlineVariant, width: 1.5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.info_outline),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Text(
                    'OpenFamily does not contact emergency services. If you '
                    'think they are in danger, call emergency services '
                    'yourself.',
                    style: AppType.body.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        if (_ackedAt != null)
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.verified_outlined, color: AppColors.sky),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'You acknowledged this ${formatAlertTime(_ackedAt!)}. '
                    '${a.senderName} can see that you did.',
                    key: const ValueKey<String>('ack-confirmation'),
                    style: AppType.body,
                  ),
                ),
              ],
            ),
          ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }
}
