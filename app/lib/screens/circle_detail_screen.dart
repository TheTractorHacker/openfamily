import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../services/server_config.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/circle_widgets.dart';

/// One circle: my sharing switch, members (with role changes and removal for
/// admins), invite codes (admins), leave and delete.
class CircleDetailScreen extends StatefulWidget {
  const CircleDetailScreen({super.key, required this.circle, this.service});

  final Circle circle;
  final CircleService? service;

  @override
  State<CircleDetailScreen> createState() => _CircleDetailScreenState();
}

class _CircleDetailScreenState extends State<CircleDetailScreen> {
  late Circle _circle = widget.circle;
  List<CircleMember> _members = <CircleMember>[];
  List<CircleInvite> _invites = <CircleInvite>[];
  String _myId = '';
  bool _loading = true;
  CircleException? _error;
  bool _sharingBusy = false;
  bool _busy = false;

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
      final String me = await _service.myUserId();
      final List<CircleMember> members = await _service.listMembers(_circle.id);
      CircleMember? mine;
      for (final CircleMember m in members) {
        if (m.userId == me) mine = m;
      }
      final bool admin = mine?.isAdmin ?? _circle.isAdmin;
      final List<CircleInvite> invites =
          admin ? await _service.listInvites(_circle.id) : <CircleInvite>[];
      if (!mounted) return;
      setState(() {
        _myId = me;
        _members = members;
        _invites = invites;
        _circle = _circle.copyWith(
          role: admin ? 'admin' : 'member',
          memberCount: members.length,
          sharingEnabled: mine?.sharingEnabled ?? _circle.sharingEnabled,
        );
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

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs a mutation, reloads on success, shows the server's message on error.
  Future<bool> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return true;
      setState(() => _busy = false);
      if (done != null) _snack(done);
      return true;
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _busy = false);
      _snack(describeCircleError(e).message);
      return false;
    }
  }

  Future<void> _toggleSharing(bool enabled) async {
    final Circle before = _circle;
    // Optimistic: the switch moves immediately; reverted if the server refuses.
    setState(() {
      _sharingBusy = true;
      _circle = _circle.copyWith(sharingEnabled: enabled);
      _members = <CircleMember>[
        for (final CircleMember m in _members)
          m.userId == _myId
              ? CircleMember(
                  userId: m.userId,
                  name: m.name,
                  role: m.role,
                  sharingEnabled: enabled)
              : m,
      ];
    });
    try {
      await _service.setSharing(_circle.id, enabled);
      if (!mounted) return;
      setState(() => _sharingBusy = false);
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sharingBusy = false;
        _circle = before;
      });
      _snack(describeCircleError(e).message);
      _load();
    }
  }

  Future<bool> _confirm(String title, String body, String action) =>
      showDsConfirm(
        context,
        title: title,
        message: body,
        confirmLabel: action,
        destructive: true,
      );

  Future<void> _remove(CircleMember m) async {
    if (!await _confirm(
        'Remove ${m.name}?',
        '${m.name} will no longer see this circle or share their location '
            'with it.',
        'Remove')) {
      return;
    }
    if (await _run(() => _service.removeMember(_circle.id, m.userId),
        done: '${m.name} was removed')) {
      _load();
    }
  }

  Future<void> _setRole(CircleMember m, String role) async {
    if (await _run(() => _service.setRole(_circle.id, m.userId, role),
        done: '${m.name} is now ${role == 'admin' ? 'an admin' : 'a member'}')) {
      _load();
    }
  }

  Future<void> _leave() async {
    if (!await _confirm(
        'Leave ${_circle.name}?',
        'You will stop sharing your location with this circle and need a '
            'new invite code to return.',
        'Leave')) {
      return;
    }
    if (await _run(() => _service.removeMember(_circle.id, 'me')) &&
        mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    if (!await _confirm(
        'Delete ${_circle.name}?',
        'This permanently deletes the circle and removes all '
            '${_members.length} members. This cannot be undone.',
        'Delete circle')) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _service.deleteCircle(_circle.id);
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      final CircleException err = describeCircleError(e);
      if (!mounted) return;
      setState(() => _busy = false);
      if (err.status == 409) {
        // The server refuses when this is some member's only circle; show its
        // message and let the admin knowingly override.
        if (await _confirm('Some members have no other circle', err.message,
            'Delete anyway')) {
          if (await _run(() => _service.deleteCircle(_circle.id, force: true)) &&
              mounted) {
            Navigator.of(context).pop();
          }
        }
      } else {
        _snack(err.message);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _rename() async {
    String draft = _circle.name;
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Rename circle'),
        content: TextFormField(
          initialValue: _circle.name,
          autofocus: true,
          onChanged: (String v) => draft = v,
          decoration: const InputDecoration(
              labelText: 'Circle name'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(draft.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == _circle.name || !mounted) {
      return;
    }
    if (await _run(() => _service.updateCircle(_circle.id, name: name)) &&
        mounted) {
      setState(() => _circle = _circle.copyWith(name: name));
    }
  }

  Future<void> _newInvite() async {
    CircleInvite? created;
    final bool ok = await _run(() async {
      created = await _service.createInvite(_circle.id);
    });
    if (ok && created != null && mounted) {
      setState(() => _invites = <CircleInvite>[created!, ..._invites]);
    }
  }

  Future<void> _revoke(CircleInvite inv) async {
    if (await _run(() => _service.revokeInvite(_circle.id, inv.id),
        done: 'Invite code revoked')) {
      if (mounted) {
        setState(() => _invites =
            _invites.where((CircleInvite i) => i.id != inv.id).toList());
      }
    }
  }

  Future<void> _share(CircleInvite inv) async {
    try {
      await Share.share(
        'Join my "${_circle.name}" circle on OpenFamily!\n\n'
        '1. Install the OpenFamily Android app\n'
        '2. Enter this server: ${ServerConfig.instance.apiBaseUrl}\n'
        '3. Use invite code ${inv.code}',
        subject: 'Join my OpenFamily circle',
      );
    } catch (_) {
      if (mounted) _snack('Could not open the share sheet');
    }
  }

  Future<void> _copy(CircleInvite inv) async {
    await Clipboard.setData(ClipboardData(text: inv.code));
    if (mounted) _snack('Code copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_circle.name, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          if (_circle.isAdmin)
            IconButton(
              tooltip: 'Rename circle',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : _rename,
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _members.isEmpty) {
      return const DsSkeletonList(rows: 5);
    }
    final CircleException? err = _error;
    if (err != null && _members.isEmpty) {
      return CircleStateMessage(
        icon: err.offline ? Icons.cloud_off_outlined : Icons.error_outline,
        title: err.offline ? 'You\'re offline' : 'Couldn\'t load this circle',
        body: err.message,
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xxl,
              AppSpace.lg,
              AppSpace.xxl,
              AppSpace.xxxl,
            ),
            children: <Widget>[
              _sharingCard(),
              _sectionTitle('Members (${_members.length})'),
              if (_members.isEmpty)
                const DsEmptyState(
                  icon: Icons.group_outlined,
                  title: 'No members to show',
                )
              else
                DsRowGroup(
                  children: <Widget>[
                    for (final CircleMember m in _members) _memberRow(m),
                  ],
                ),
              if (_circle.isAdmin) ...<Widget>[
                _sectionTitle('Invite codes'),
                ..._inviteSection(),
              ],
              const SizedBox(height: AppSpace.xxl),
              DsPillButton(
                style: DsPillStyle.outlined,
                onPressed: _busy ? null : _leave,
                icon: Icons.logout,
                label: 'Leave circle',
              ),
              if (_circle.isAdmin) ...<Widget>[
                const SizedBox(height: AppSpace.md),
                DsPillButton(
                  style: DsPillStyle.danger,
                  onPressed: _busy ? null : _delete,
                  icon: Icons.delete_outline,
                  label: 'Delete circle',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => DsSectionHeader(
        text,
        padding: const EdgeInsets.only(
          top: AppSpace.xl,
          bottom: AppSpace.sm,
        ),
      );

  Widget _sharingCard() {
    final bool on = _circle.sharingEnabled;
    return DsRowGroup(
      children: <Widget>[
        DsToggleRow(
          icon: on ? Icons.location_on : Icons.location_off_outlined,
          title: 'Share my location',
          subtitle: on
              ? 'Sharing: members of this circle can see where you are.'
              : 'Paused: nobody in this circle can see where you are.',
          value: on,
          onChanged: _sharingBusy ? null : _toggleSharing,
        ),
      ],
    );
  }

  Widget _memberRow(CircleMember m) {
    final bool isMe = m.userId == _myId;
    final bool canManage = _circle.isAdmin && !isMe;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '${m.name}${isMe ? ', you' : ''}, ${m.isAdmin ? 'admin' : 'member'}, '
          'location ${m.sharingEnabled ? 'shared' : 'not shared'}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  AppSpace.md,
                  0,
                  AppSpace.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(isMe ? '${m.name} (you)' : m.name,
                        style: AppType.body),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        RoleBadge(role: m.role),
                        Icon(
                          m.sharingEnabled
                              ? Icons.location_on
                              : Icons.location_off_outlined,
                          size: 15,
                          color: m.sharingEnabled
                              ? AppColors.statusGreen
                              : cs.onSurfaceVariant,
                        ),
                        Text(m.sharingEnabled ? 'Sharing' : 'Paused',
                            style: AppType.secondary
                                .copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (canManage)
              PopupMenuButton<String>(
                tooltip: 'Manage ${m.name}',
                enabled: !_busy,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onSelected: (String v) {
                  if (v == 'remove') {
                    _remove(m);
                  } else {
                    _setRole(m, v);
                  }
                },
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  if (m.isAdmin)
                    const PopupMenuItem<String>(
                        value: 'member', child: Text('Make member'))
                  else
                    const PopupMenuItem<String>(
                        value: 'admin', child: Text('Make admin')),
                  const PopupMenuItem<String>(
                      value: 'remove', child: Text('Remove from circle')),
                ],
              )
            else
              const SizedBox(width: AppSpace.xl),
          ],
        ),
      ),
    );
  }

  List<Widget> _inviteSection() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return <Widget>[
      for (final CircleInvite inv in _invites)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.xs,
              AppSpace.md,
            ),
            decoration: BoxDecoration(
              color: BrandTheme.of(context).sheet,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Semantics(
                        label: 'Invite code ${inv.code.split('').join(' ')}',
                        child: Text(inv.code,
                            style: AppType.title.copyWith(letterSpacing: 4)),
                      ),
                      Text(
                        'Used ${inv.uses} of ${inv.maxUses}',
                        style: AppType.secondary
                            .copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copy code',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copy(inv),
                ),
                IconButton(
                  tooltip: 'Share code',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.share),
                  onPressed: () => _share(inv),
                ),
                IconButton(
                  tooltip: 'Revoke code',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy ? null : () => _revoke(inv),
                ),
              ],
            ),
          ),
        ),
      if (_invites.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: Text(
            'No active invite codes.',
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      DsPillButton(
        onPressed: _busy ? null : _newInvite,
        icon: Icons.person_add_alt_1,
        label: 'New invite code',
      ),
    ];
  }
}
