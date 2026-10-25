import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const <Widget>[
            Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No alerts yet. Check-ins, help requests and SOS from your '
                'family will be listed here.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
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
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: <Widget>[
          if (_moreError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_moreError!, textAlign: TextAlign.center),
            ),
          _loadingMore
              ? const CircularProgressIndicator()
              : OutlinedButton(
                  onPressed: _more, child: const Text('Load older alerts')),
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
      child: ListTile(
        minVerticalPadding: 12,
        leading: Icon(icon,
            color: alert.kind == AlertKind.sos
                ? AppColors.sosRed
                : BrandTheme.of(context).accentInk),
        title: Text(who),
        subtitle: Text(line),
        trailing: alert.isActive
            ? const Icon(Icons.radio_button_checked,
                size: 18, color: AppColors.statusOrange)
            : const Icon(Icons.check_circle_outline, size: 18),
        onTap: onTap,
      ),
    );
  }
}
