import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../theme/app_theme.dart';
import '../widgets/circle_widgets.dart';
import '../widgets/ds/ds.dart';
import 'circle_create_screen.dart';
import 'circle_detail_screen.dart';

/// Lists every circle the user belongs to (`GET /circles`) with role badges
/// and each circle's sharing status. Entry point for creating, joining and
/// managing circles.
class CirclesScreen extends StatefulWidget {
  const CirclesScreen({super.key, this.service});

  final CircleService? service;

  @override
  State<CirclesScreen> createState() => _CirclesScreenState();
}

class _CirclesScreenState extends State<CirclesScreen> {
  List<Circle>? _circles;
  CircleException? _error;
  bool _loading = true;

  CircleService get _service => widget.service ?? CircleService.instance;

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
      final List<Circle> circles = await _service.listCircles();
      if (!mounted) return;
      setState(() {
        _circles = circles;
        _loading = false;
      });
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeCircleError(e);
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final Circle? c = await Navigator.of(context).push<Circle>(
      MaterialPageRoute<Circle>(
          builder: (_) => CircleCreateScreen(service: widget.service)),
    );
    if (c != null) _load();
  }

  Future<void> _join() async {
    String draft = '';
    final String? code = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Join a circle'),
        content: TextField(
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          onChanged: (String v) => draft = v,
          decoration: const InputDecoration(
            labelText: 'Invite code',
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(draft.trim()),
              child: const Text('Join')),
        ],
      ),
    );
    if (code == null || code.isEmpty || !mounted) return;
    try {
      await _service.joinCircle(code);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('You joined the circle')));
      _load();
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeCircleError(e).message)));
    }
  }

  Future<void> _open(Circle c) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => CircleDetailScreen(circle: c, service: widget.service)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Circles'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Join a circle with a code',
            constraints: const BoxConstraints(
              minWidth: kMinTarget,
              minHeight: kMinTarget,
            ),
            icon: const Icon(Icons.vpn_key_outlined),
            onPressed: _join,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New circle'),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _circles == null) {
      return const DsSkeletonList(rows: 4);
    }
    final CircleException? err = _error;
    if (err != null && _circles == null) {
      return CircleStateMessage(
        icon: err.offline ? Icons.cloud_off_outlined : Icons.error_outline,
        title: err.offline ? 'You\'re offline' : 'Couldn\'t load circles',
        body: err.message,
        onAction: _load,
      );
    }
    final List<Circle> circles = _circles ?? <Circle>[];
    if (circles.isEmpty) {
      return CircleStateMessage(
        icon: Icons.group_add_outlined,
        title: 'No circles yet',
        body: 'Create a circle for your family or friends, or join one with '
            'an invite code.',
        actionLabel: 'Create a circle',
        onAction: _create,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          96,
        ),
        itemCount: circles.length,
        itemBuilder: (BuildContext context, int i) => _CircleTile(
          circle: circles[i],
          onTap: () => _open(circles[i]),
        ),
      ),
    );
  }
}

class _CircleTile extends StatelessWidget {
  const _CircleTile({required this.circle, required this.onTap});

  final Circle circle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool sharing = circle.sharingEnabled;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String members =
        '${circle.memberCount} ${circle.memberCount == 1 ? 'member' : 'members'}';
    return Semantics(
      button: true,
      label: '${circle.name}, ${circle.isAdmin ? 'admin' : 'member'}, '
          '$members, location ${sharing ? 'shared' : 'not shared'}',
      excludeSemantics: true,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Material(
          color: BrandTheme.of(context).sheet,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Row(
                  children: <Widget>[
                    CircleIconAvatar(circle: circle),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(circle.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.headline),
                          const SizedBox(height: AppSpace.xs),
                          Wrap(
                            spacing: AppSpace.sm,
                            runSpacing: AppSpace.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              RoleBadge(role: circle.role),
                              Text(members,
                                  style: AppType.secondary
                                      .copyWith(color: cs.onSurfaceVariant)),
                              DsStatusChip(
                                label: sharing ? 'Sharing' : 'Paused',
                                icon: sharing
                                    ? Icons.location_on
                                    : Icons.location_off_outlined,
                                color: sharing
                                    ? AppColors.statusGreen
                                    : AppColors.statusGrey,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
