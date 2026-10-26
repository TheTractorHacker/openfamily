import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'alert_received_screen.dart';
import 'alert_status_screen.dart';

/// Family alert history (newest first): who, when, what type, and for your
/// own alerts a delivery summary on the detail screen.
class AlertsHistoryScreen extends StatefulWidget {
  const AlertsHistoryScreen({
    super.key,
    this.service = const AlertService(),
    this.selfUserId,
    this.pageSize = 20,
  });

  final AlertService service;

  /// Defaults to the id learned from the WebSocket welcome frame.
  final String? selfUserId;
  final int pageSize;

  @override
  State<AlertsHistoryScreen> createState() => _AlertsHistoryScreenState();
}

class _AlertsHistoryScreenState extends State<AlertsHistoryScreen> {
  final List<AlertSummary> _items = <AlertSummary>[];
  String? _next;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;

  String? get _self => widget.selfUserId ?? AlertEvents.selfUserId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final AlertPage p = await widget.service.list(limit: widget.pageSize);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(p.alerts);
        _next = p.nextBefore;
        _loading = false;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = alertErrorMessage(e, action: 'load alerts');
      });
    }
  }

  Future<void> _more() async {
    final String? before = _next;
    if (before == null || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final AlertPage p =
          await widget.service.list(limit: widget.pageSize, before: before);
      if (!mounted) return;
      setState(() {
        _items.addAll(p.alerts);
        _next = p.nextBefore;
        _loadingMore = false;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _moreError = alertErrorMessage(e, action: 'load more');
      });
    }
  }

  void _open(AlertSummary a) {
    final bool mine = _self != null && a.userId == _self;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => mine
          ? AlertStatusScreen(
              alertId: a.id, kind: a.kind, service: widget.service)
          : AlertReceivedScreen(alert: a, service: widget.service),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alert history')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.xl),
        child: DsSkeletonList(rows: 5),
      );
    }
    if (_error != null) {
      return DsErrorState(
        icon: Icons.cloud_off,
        title: 'Could not load alerts',
        message: _error!,
        onRetry: _load,
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            SizedBox(height: AppSpace.xxxl),
            DsEmptyState(
              icon: Icons.notifications_none,
              title: 'No alerts yet',
              message: 'Check-ins, help requests and SOS from your family '
                  'will be listed here.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _items.length + (_next != null ? 1 : 0),
            itemBuilder: (BuildContext context, int i) {
              if (i == _items.length) return _footer();
              return AlertTile(
                alert: _items[i],
                isMine: _self != null && _items[i].userId == _self,
                onTap: () => _open(_items[i]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_moreError != null) DsMessage(_moreError!),
          const SizedBox(height: AppSpace.sm),
          _loadingMore
              ? const Center(child: CircularProgressIndicator())
              : DsPillButton(
                  label: 'Load older alerts',
                  style: DsPillStyle.outlined,
                  onPressed: _more,
                ),
        ],
      ),
    );
  }
}

class AlertTile extends StatelessWidget {
  const AlertTile({
    super.key,
    required this.alert,
    required this.isMine,
    required this.onTap,
  });

  final AlertSummary alert;
  final bool isMine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (alert.kind) {
      AlertKind.sos => Icons.sos,
      AlertKind.help => Icons.campaign_outlined,
      AlertKind.checkIn => Icons.location_on_outlined,
      AlertKind.unknown => Icons.notifications_none,
    };
    final String who = isMine ? 'You' : alert.senderName;
    final String status = alert.isActive ? 'Active' : 'Resolved';
    final String line =
        '${alertKindLabel(alert.kind)} · ${formatAlertTime(alert.createdAt)} · $status';
    return Semantics(
      button: true,
      label: '$who, $line',
      excludeSemantics: true,
      child: DsListRow(
        title: who,
        subtitle: line,
        leading: DsListRow.iconTile(
          context,
          icon,
          color: alert.kind == AlertKind.sos ? AppColors.sosRed : null,
        ),
        trailing: Align(
          alignment: Alignment.centerRight,
          child: DsStatusChip(
            label: status,
            icon: alert.isActive
                ? Icons.radio_button_checked
                : Icons.check_circle_outline,
            color: alert.isActive
                ? AppColors.statusOrange
                : AppColors.statusGrey,
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
