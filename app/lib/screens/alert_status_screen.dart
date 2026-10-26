import 'dart:async';

import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Icon + colour for a delivery state. The icon shape differs per state so
/// the meaning never depends on colour alone.
({IconData icon, Color color}) deliveryStateStyle(
    BuildContext context, DeliveryState s) {
  switch (s) {
    case DeliveryState.queued:
      return (icon: Icons.schedule, color: AppColors.statusGrey);
    case DeliveryState.sent:
      return (icon: Icons.check, color: AppColors.statusOrange);
    case DeliveryState.delivered:
      return (icon: Icons.done_all, color: AppColors.statusGreen);
    case DeliveryState.failed:
      return (icon: Icons.error_outline, color: AppColors.sosRed);
    case DeliveryState.acknowledged:
      return (icon: Icons.verified_outlined, color: AppColors.sky);
  }
}

/// Sender-side status screen for an alert that was just sent (or opened from
/// history): states the truth about who was told and how, and keeps
/// recipient delivery states current.
class AlertStatusScreen extends StatelessWidget {
  const AlertStatusScreen({
    super.key,
    required this.alertId,
    this.kind = AlertKind.unknown,
    this.service = const AlertService(),
    this.dialer = const EmergencyDialer(),
    this.pollInterval = const Duration(seconds: 4),
  });

  final String alertId;
  final AlertKind kind;
  final AlertService service;
  final EmergencyDialer dialer;
  final Duration pollInterval;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${alertKindLabel(kind)} status')),
      body: SafeArea(
        child: AlertStatusBody(
          alertId: alertId,
          kind: kind,
          service: service,
          dialer: dialer,
          pollInterval: pollInterval,
          footer: <Widget>[
            DsPillButton(
              label: 'Done',
              style: DsPillStyle.tonal,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The status content, embeddable in the send flows. Polls while any delivery
/// is still expected to change, and refreshes on `alert_ack` WebSocket frames.
class AlertStatusBody extends StatefulWidget {
  const AlertStatusBody({
    super.key,
    required this.alertId,
    this.kind = AlertKind.unknown,
    this.service = const AlertService(),
    this.dialer = const EmergencyDialer(),
    this.pollInterval = const Duration(seconds: 4),
    this.footer = const <Widget>[],
    this.title,
  });

  final String alertId;
  final AlertKind kind;
  final AlertService service;
  final EmergencyDialer dialer;
  final Duration pollInterval;
  final List<Widget> footer;
  final String? title;

  @override
  State<AlertStatusBody> createState() => _AlertStatusBodyState();
}

class _AlertStatusBodyState extends State<AlertStatusBody> {
  static const int _maxPolls = 45;

  AlertDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _revoking = false;
  bool _revoked = false;
  int _polls = 0;
  Timer? _timer;
  StreamSubscription<Map<String, dynamic>>? _ackSub;

  @override
  void initState() {
    super.initState();
    _ackSub = AlertEvents.acks.listen((Map<String, dynamic> f) {
      if (f['alert_id'] == widget.alertId) _refresh();
    });
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ackSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    try {
      final AlertDetail d = await widget.service.detail(widget.alertId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _error = null;
        _loading = false;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = alertErrorMessage(e, action: 'check delivery');
        _loading = false;
      });
    }
    if (!mounted) return;
    final AlertDetail? d = _detail;
    final bool keepGoing = _polls < _maxPolls && (d == null || !d.isSettled);
    if (keepGoing) {
      _polls++;
      _timer = Timer(widget.pollInterval, _refresh);
    }
  }

  Future<void> _retry() async {
    setState(() {
      _loading = _detail == null;
      _polls = 0;
    });
    await _refresh();
  }

  Future<void> _revoke() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Turn off location link?'),
        content: const Text(
            'The link in text messages to your emergency contacts stops '
            'working right away. They will no longer see your last known '
            'position through it.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('Keep link')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('Turn off')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _revoking = true);
    try {
      await widget.service.revokeShare(widget.alertId);
      if (!mounted) return;
      setState(() {
        _revoking = false;
        _revoked = true;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _revoking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(alertErrorMessage(e, action: 'turn off the link'))),
      );
    }
  }

  Future<void> _call() async {
    final bool ok = await widget.dialer.dial();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open the phone app. Dial your local '
            'emergency number yourself.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AlertDetail? d = _detail;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color muted = cs.onSurfaceVariant;
    final List<RecipientDeliveries> people =
        d?.recipients ?? const <RecipientDeliveries>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.lg,
        AppSpace.xl,
        AppSpace.xxl,
      ),
      children: <Widget>[
        Semantics(
          header: true,
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.notifications_active_outlined,
                size: 32,
                color: AppColors.statusGreen,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  widget.title ?? '${alertKindLabel(widget.kind)} sent',
                  style: AppType.title.copyWith(fontSize: 26),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        Container(
          key: const ValueKey<String>('alert-honesty-banner'),
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: BrandTheme.of(context).sheet,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cs.outlineVariant, width: 1.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.info_outline, color: cs.onSurface),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  kFamilyNotifiedLine,
                  style: AppType.headline.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        EmergencyCallButton(dialer: widget.dialer, onPressed: _call),
        const SizedBox(height: AppSpace.xl),
        const DsSectionHeader('Delivery'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.sm),
            child: DsSkeletonList(rows: 2, avatar: false),
          )
        else ...<Widget>[
          if (_error != null) _ErrorBox(message: _error!, onRetry: _retry),
          if (d != null) ...<Widget>[
            Semantics(
              liveRegion: true,
              child: Text(
                d.summaryLine,
                key: const ValueKey<String>('delivery-summary'),
                style: AppType.secondary.copyWith(fontSize: 14, color: muted),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            if (people.isEmpty)
              Text(
                'No delivery details yet. Nobody else in your family may '
                'have the app set up for notifications.',
                style: AppType.secondary.copyWith(fontSize: 14, color: muted),
              ),
            for (final RecipientDeliveries p in people)
              RecipientCard(person: p),
            if (people.any((RecipientDeliveries p) => p.anyFailed))
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Text(
                  'Some messages did not go through. Call or message those '
                  'people directly, or use the call button above if you '
                  'need help now.',
                  style: AppType.secondary.copyWith(
                    fontSize: 14,
                    color: muted,
                  ),
                ),
              ),
            if (!d.isSettled && _polls >= _maxPolls)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: DsPillButton(
                  label: 'Refresh status',
                  icon: Icons.refresh,
                  style: DsPillStyle.outlined,
                  onPressed: _retry,
                ),
              ),
            if (d.hasSms && d.summary.isActive) ...<Widget>[
              const SizedBox(height: AppSpace.lg),
              if (_revoked)
                Row(
                  children: <Widget>[
                    const Icon(Icons.link_off, size: 20),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        'Location link turned off.',
                        style: AppType.secondary.copyWith(
                          fontSize: 14,
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                )
              else
                DsPillButton(
                  label: 'Turn off location link',
                  icon: Icons.link_off,
                  style: DsPillStyle.outlined,
                  onPressed: _revoking ? null : _revoke,
                ),
            ],
          ],
        ],
        const SizedBox(height: AppSpace.md),
        ...widget.footer,
      ],
    );
  }
}

/// The regional emergency dial button. Opens the phone app's dialler with
/// the local emergency number; it never places the call by itself.
class EmergencyCallButton extends StatelessWidget {
  const EmergencyCallButton({
    super.key,
    required this.dialer,
    required this.onPressed,
  });
  final EmergencyDialer dialer;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!dialer.available) {
      return Text(
        'If you are in danger, call your local emergency number now.',
        style: AppType.body.copyWith(height: 1.4),
      );
    }
    return KeyedSubtree(
      key: const ValueKey<String>('call-emergency-button'),
      child: DsPillButton(
        label: 'Call emergency services',
        icon: Icons.call,
        style: DsPillStyle.danger,
        onPressed: onPressed,
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.error_outline, color: AppColors.sosRed),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: Text(message, style: AppType.body)),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            DsPillButton(
              label: 'Retry',
              style: DsPillStyle.tonal,
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// One recipient with a row per channel; each row has an icon, a text label
/// and (for failures) the reason.
class RecipientCard extends StatelessWidget {
  const RecipientCard({super.key, required this.person});
  final RecipientDeliveries person;

  @override
  Widget build(BuildContext context) {
    final Color muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(top: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BrandTheme.of(context).sheet,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            person.isContact
                ? '${person.name} (emergency contact)'
                : person.name,
            style: AppType.headline,
          ),
          for (final AlertDelivery row in person.rows)
            _DeliveryRow(row: row, muted: muted),
        ],
      ),
    );
  }
}

class _DeliveryRow extends StatelessWidget {
  const _DeliveryRow({required this.row, required this.muted});
  final AlertDelivery row;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final style = deliveryStateStyle(context, row.state);
    final String channel = deliveryChannelLabel(row.channel);
    final String state = deliveryStateLabel(row.state);
    return Semantics(
      container: true,
      label: '$channel: $state'
          '${row.state == DeliveryState.failed ? '. ${deliveryErrorLabel(row.error)}' : ''}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(style.icon, size: 22, color: style.color),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('$channel: $state', style: AppType.body),
                  if (row.state == DeliveryState.failed)
                    Text(
                      deliveryErrorLabel(row.error),
                      style: AppType.secondary.copyWith(
                        fontSize: 14,
                        color: muted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
