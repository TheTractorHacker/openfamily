import 'package:flutter/material.dart';

import '../models/inbox.dart';
import '../services/inbox_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'alert_received_screen.dart' show formatAlertTime;
import 'app_shell.dart';

/// "Activity": check-ins other people sent you and live shares they started
/// with you. Tapping a row focuses that person on the map.
class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    this.service = const ApiInboxService(),
    this.onOpenMember,
  });

  final InboxService service;

  /// Defaults to switching to the map tab and focusing the member there.
  final void Function(BuildContext context, InboxItem item)? onOpenMember;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<InboxItem> _items = const <InboxItem>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    InboxStore.instance.markSeen();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _items.isEmpty;
      _error = null;
    });
    try {
      final List<InboxItem> l = await widget.service.load();
      if (!mounted) return;
      InboxStore.instance.items.value = l;
      InboxStore.instance.markSeen();
      setState(() {
        _items = l;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Check your connection and try again.';
      });
    }
  }

  void _open(InboxItem item) {
    final void Function(BuildContext, InboxItem)? custom = widget.onOpenMember;
    if (custom != null) {
      custom(context, item);
      return;
    }
    InboxFocus.memberId.value = item.userId;
    AppShell.requestTab(AppTab.location);
    Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.xl),
        child: DsSkeletonList(rows: 4),
      );
    }
    if (_error != null && _items.isEmpty) {
      return DsErrorState(
        icon: Icons.cloud_off,
        title: 'Could not load activity',
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
              title: 'Nothing yet',
              message: 'Check-ins and live location shares from your circle '
                  'will show up here.',
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
            itemCount: _items.length,
            itemBuilder: (BuildContext context, int i) =>
                InboxTile(item: _items[i], onTap: () => _open(_items[i])),
          ),
        ),
      ),
    );
  }
}

class InboxTile extends StatelessWidget {
  const InboxTile({super.key, required this.item, required this.onTap, this.now});

  final InboxItem item;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final DateTime n = now ?? DateTime.now();
    final bool share = item.kind == InboxKind.liveShare;
    final String when = formatAlertTime(item.at, now: n);
    final String sub = share
        ? 'Live location · ${item.paused ? 'paused' : 'until ${_hm(item.expiresAt)}'}'
        : '$when${item.hasPin ? ' · pin on map' : ''}';
    return Semantics(
      button: true,
      label: '${item.title}. $sub',
      excludeSemantics: true,
      child: DsListRow(
        title: item.title,
        subtitle: sub,
        leading: DsListRow.iconTile(
          context,
          share ? Icons.my_location : Icons.location_on_outlined,
        ),
        trailing: item.hasPin && !share
            ? const Icon(Icons.place_outlined)
            : null,
        chevron: true,
        onTap: onTap,
      ),
    );
  }

  static String _hm(DateTime? t) => t == null
      ? '—'
      : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// A slim banner offering the newest unseen check-in / share; shown above the
/// map. Renders nothing when there is nothing new.
class InboxBanner extends StatelessWidget {
  const InboxBanner({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: InboxStore.instance.unseen,
      builder: (BuildContext context, int count, _) {
        final InboxItem? item = InboxStore.instance.newestUnseen;
        if (count == 0 || item == null) return const SizedBox.shrink();
        final ColorScheme cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: Material(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: InkWell(
              key: const ValueKey<String>('inbox-banner'),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.lg,
                  vertical: AppSpace.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.location_on_outlined,
                        size: 18, color: cs.onSecondaryContainer),
                    const SizedBox(width: AppSpace.sm),
                    Flexible(
                      child: Text(
                        count > 1 ? '${item.title} (+${count - 1})' : item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.secondary
                            .copyWith(color: cs.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
