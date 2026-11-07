import 'dart:async';

import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/delivery_status.dart';
import '../services/e2ee/private_runtime.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// "Why can't I see everyone?" for a Private circle: for each member, in plain
/// words, why their updates are or are not arriving, what this phone itself has
/// done, and a one-tap "Fix this circle". See docs/troubleshooting/no-locations.md.
class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({super.key, required this.circle, this.runtime, this.loader});
  final Circle circle;
  final PrivateRuntime? runtime;

  /// Test hook: replaces the server call.
  final Future<CircleDelivery?> Function(String circleId)? loader;

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  PrivateRuntime get _rt => widget.runtime ?? PrivateRuntime.instance;
  CircleDelivery? _report;
  LocalDelivery? _local;
  bool _loading = true;
  bool _unavailable = false;
  bool _fixing = false;
  List<String> _fixed = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final CircleDelivery? d = await (widget.loader ?? DeliveryMonitor.fetch)(widget.circle.id);
    LocalDelivery? l;
    try {
      l = await _rt.localDelivery(widget.circle.id);
    } catch (_) {}
    if (d != null) DeliveryHints.put(d);
    if (!mounted) return;
    setState(() {
      _report = d;
      _local = l;
      _unavailable = d == null;
      _loading = false;
    });
  }

  Future<void> _fix() async {
    setState(() {
      _fixing = true;
      _fixed = <String>[];
    });
    List<String> done;
    try {
      done = await _rt.fixCircle(widget.circle.id);
    } catch (_) {
      done = <String>["Something went wrong while fixing. Check the connection and try again."];
    }
    if (!mounted) return;
    setState(() {
      _fixing = false;
      _fixed = done;
    });
    await _load();
  }

  String _ago(DateTime? t) => t == null ? 'never' : deliveryTimeLabel(t);

  /// Things wrong on THIS phone, in words.
  List<String> _myProblems() {
    final LocalDelivery? l = _local;
    final List<String> out = <String>[];
    if (l == null) return out;
    if (!l.hasKey) out.add('This phone does not have the circle key yet, so it can neither send nor show positions. Tap "Fix this circle".');
    if (l.parked > 0) out.add('${l.parked} position${l.parked == 1 ? ' is' : 's are'} waiting for the circle key.');
    if (l.queued > 0) out.add('${l.queued} update${l.queued == 1 ? ' is' : 's are'} waiting for a connection.');
    if (l.undelivered > 0) {
      out.add('${l.undelivered} update${l.undelivered == 1 ? ' was' : 's were'} refused by the server (${l.undeliveredCode}). Updating the app or asking an admin to approve this phone usually fixes it.');
    }
    final MemberDelivery? me = _report?.members.cast<MemberDelivery?>().firstWhere((MemberDelivery? m) => m!.you, orElse: () => null);
    if (me != null && me.reason == DeliveryReason.sharingPaused) out.add('You paused location sharing for this circle.');
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final CircleDelivery? r = _report;
    final List<String> mine = _myProblems();
    return DsPage(
      title: "Why can't I see everyone?",
      actions: <Widget>[
        DsPillButton(
          key: const Key('delivery-fix'),
          label: _fixing ? 'Fixing…' : 'Fix this circle',
          onPressed: _fixing ? null : _fix,
        ),
      ],
      children: <Widget>[
        Text(widget.circle.name, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpace.md),
        if (_loading && r == null) const Center(child: CircularProgressIndicator()),
        if (r != null && r.nobodySending)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Text(kNobodySendingText, key: const Key('delivery-nobody'), style: AppType.body),
          ),
        if (_unavailable && !_loading)
          Text(
            "The server could not tell us. It may be an older version, or you may be offline. Tap \"Fix this circle\" to refresh this phone anyway.",
            key: const Key('delivery-unavailable'),
            style: AppType.secondary,
          ),
        if (mine.isNotEmpty) ...<Widget>[
          Text('This phone', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          for (final String p in mine) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $p', style: AppType.body)),
          const SizedBox(height: AppSpace.md),
        ],
        if (_local != null)
          Text(
            'This phone last sent an update ${_ago(_local!.lastSealedAt)}.',
            key: const Key('delivery-mine-last'),
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
        const SizedBox(height: AppSpace.md),
        if (r != null) ...<Widget>[
          Text('Everyone in this circle', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          for (final MemberDelivery m in r.members.where((MemberDelivery m) => !m.you)) _memberRow(m),
        ],
        if (_fixed.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpace.md),
          Text('What we just did', style: AppType.headline),
          for (final String f in _fixed) Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $f', key: const Key('delivery-fixed'), style: AppType.body)),
        ],
      ],
    );
  }

  Widget _memberRow(MemberDelivery m) {
    final String? why = describeMemberDelivery(m);
    final String? advice = deliveryAdvice(m);
    final String last = m.lastItemAt == null ? 'No encrypted update received yet' : 'Last encrypted update: ${deliveryTimeLabel(m.lastItemAt!)}';
    return Padding(
      key: Key('delivery-member-${m.userId}'),
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(m.name, style: AppType.body.copyWith(fontWeight: FontWeight.w600)),
          Text(why ?? 'Sending normally', style: AppType.body),
          Text(last, style: AppType.secondary),
          if (advice != null) Text(advice, style: AppType.secondary),
        ],
      ),
    );
  }
}
