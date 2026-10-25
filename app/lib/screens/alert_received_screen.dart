import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';

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
    final Color muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final bool urgent = a.kind == AlertKind.sos && a.isActive;
    final String headline = switch (a.kind) {
      AlertKind.sos => '${a.senderName} sent an SOS',
      AlertKind.help => '${a.senderName} asked for help',
      AlertKind.checkIn => '${a.senderName} checked in',
      AlertKind.unknown => 'Alert from ${a.senderName}',
    };
    return Scaffold(
      appBar: AppBar(title: Text(alertKindLabel(a.kind))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Semantics(
              header: true,
              liveRegion: true,
              child: Row(
                children: <Widget>[
                  Icon(
                    urgent ? Icons.warning_amber_rounded : Icons.notifications_none,
                    size: 36,
                    color: urgent ? AppColors.sosRed : BrandTheme.of(context).accentInk,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(headline,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${formatAlertTime(a.createdAt)} · ${a.isActive ? 'Active' : 'Resolved'}',
              style: TextStyle(color: muted),
            ),
            if (a.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('"${a.note}"', style: const TextStyle(fontSize: 16)),
            ],
            if (urgent) ...<Widget>[
              const SizedBox(height: 12),
              const Text(
                'OpenFamily does not contact emergency services. If you '
                'think they are in danger, call emergency services yourself.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 20),
            if (_ackedAt != null)
              Semantics(
                liveRegion: true,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.verified_outlined, color: AppColors.sky),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You acknowledged this ${formatAlertTime(_ackedAt!)}. '
                        '${a.senderName} can see that you did.',
                        key: const ValueKey<String>('ack-confirmation'),
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  key: const ValueKey<String>('ack-button'),
                  onPressed: _busy ? null : _ack,
                  icon: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('Acknowledge',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Row(children: <Widget>[
                  const Icon(Icons.error_outline, color: AppColors.sosRed),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!)),
                ]),
              ),
            ],
            if (widget.dialer.available) ...<Widget>[
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: widget.dialer.dial,
                  icon: const Icon(Icons.call),
                  label: const Text('Call emergency services'),
                ),
              ),
            ],
            if (widget.onOpenMap != null) ...<Widget>[
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: TextButton.icon(
                  onPressed: widget.onOpenMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Open the map'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
