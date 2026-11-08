import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../services/e2ee/e2ee_app.dart';
import 'delivery_screen.dart';
import '../services/e2ee/private_runtime.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/server_config.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/circle_widgets.dart';
import '../widgets/add_server_sheet.dart';
import '../widgets/trusted_server_prompt.dart';
import 'processing_screen.dart';
import 'encryption_keys_screen.dart';

/// Extension presets for an admin, label to hours.
const Map<String, int> kTempCircleExtensions = <String, int>{
  '1 day': 24,
  '3 days': 72,
  '1 week': 168,
};

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

  // Private circle (end-to-end encryption, phase 1). Only loaded in the real
  // app (widget.service == null); tests and previews never touch it.
  E2eeService? get _e2ee => widget.service == null ? E2eeApp.service : null;
  CircleE2eeState? _e2eeState;
  bool _e2eeBusy = false;

  Future<void> _loadE2ee() async {
    final E2eeService? svc = _e2ee;
    if (svc == null) return;
    try {
      final CircleE2eeState st = await svc.api.circleState(_circle.id);
      if (mounted) setState(() => _e2eeState = st);
    } catch (_) {
      // Older server without the endpoints: the toggle simply stays hidden.
    }
  }

  static const String _privateOnMessage =
      'From now on, in this circle: live positions, location history, places, arrival and departure '
              'events and the position in check-ins and SOS are encrypted on each phone. The server '
              'stores and forwards ciphertext only and cannot read where anyone is.\n\n'
              'Still visible to the server: who is in the circle, when phones are online and how often '
              'they upload. Chat in this circle is end-to-end encrypted too.\n\n'
              'Trips, driving reports and the weekly summary: members who keep their data on their phone get them '
              'calculated by their own phone (it may use more battery and data and can arrive late). The admin map, '
              'Dawarich export and place alerts made by the server only work for members who allow server processing; '
              'your phones work out arrivals and departures. SOS reaches your circle, but the server and any SMS contact '
              'cannot be told the position.\n\n'
              'Optional later: a circle admin can turn on server processing (Encryption keys > this circle > Server '
              'processing). Each member then decides for themselves whether the server may read their data; the server '
              'operator can read the data of members who allow it. Nobody can opt in another member.\n\n'
              'Existing places are re-encrypted and the server copies deleted. Location history the server '
              'already holds stays until each person deletes it in their settings. Every member needs the '
              'latest app and an approved phone. If every phone and the recovery phrase are lost, encrypted '
              'data cannot be recovered.';

  Future<void> _togglePrivate(bool on) async {
    final E2eeService? svc = _e2ee;
    if (svc == null || _e2eeBusy) return;
    // When the admin recommends trusting the server, offer the choice (trusted
    // preselected, strict one tap away). It is only a recommendation: no consent
    // is ever sent from here.
    bool recommended = false;
    if (on) {
      try {
        recommended = await svc.api.trustedServerDefault();
      } catch (_) {}
    }
    if (!mounted) return;
    PrivateModeChoice? choice;
    final bool ok = recommended
        ? ((choice = await showDialog<PrivateModeChoice>(
                context: context,
                builder: (BuildContext ctx) => PrivateModeChoiceDialog(message: _privateOnMessage))) !=
            null)
        : await showDsConfirm(
      context,
      title: on ? 'Make this a private circle?' : 'Turn off private mode?',
      message: on
          ? _privateOnMessage
          : 'The circle goes back to normal mode and its encrypted items and key copies are deleted from the '
              'server. Places and history that exist only on phones stay there; the server will not have them. '
              'Keys already on phones stay there.',
      confirmLabel: on ? 'Turn on' : 'Turn off',
      destructive: !on,
    );
    if (!ok || !mounted) return;
    setState(() => _e2eeBusy = true);
    try {
      if (on) {
        final LocalIdentity? id = await svc.identity();
        if (id == null) await svc.registerThisDevice(label: 'This phone');
        await svc.enableCircle(_circle.id);
        // Migration: seal this circle's existing places, then delete the server's plaintext copies.
        try {
          final int moved = await PrivateRuntime.instance.migratePlaces(_circle.id, primary: _circle.isPrimary);
          if (mounted && moved > 0) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('$moved ${moved == 1 ? 'place was' : 'places were'} encrypted and removed from the server.')));
          }
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Private mode is on, but existing places could not be moved yet. Open Places to retry.')));
          }
        }
      } else {
        await svc.disableCircle(_circle.id);
      }
      await _loadE2ee();
      try {
        await PrivateRuntime.instance.setCircles(await _service.listCircles());
      } catch (_) {}
      if (on && choice == PrivateModeChoice.trusted && mounted) {
        // Lead the person to the processing screen, where each choice needs an explicit confirmation. Nothing is signed here.
        await Navigator.of(context).push<void>(MaterialPageRoute<void>(
            builder: (_) => ProcessingScreen(circle: _circle, service: svc)));
      } else if (on && mounted) {
        // Offer the one-tap sheet right after the circle becomes private; it explains itself
        // when the server is not set up. Nothing is signed unless the person taps OK.
        await showAddServerSheet(context, circle: _circle.copyWith(e2eeMode: 'private'));
      }
    } on NeedsCrossSignatureException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } catch (e) {
      final CircleException err = describeCircleError(e);
      if (mounted) {
        if (err.keyProblem != null) {
          setState(() => _e2eeBusy = false);
          await showPrivateKeyProblem(context, err, turningOff: !on);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.message)));
        }
      }
    } finally {
      if (mounted) setState(() => _e2eeBusy = false);
    }
  }

  Widget _deliveryRow() {
    if (!_circle.isPrivate) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: DsRowGroup(
        children: <Widget>[
          DsListRow(
            key: const Key('circle-why-cant-i-see'),
            leading: DsListRow.iconTile(context, Icons.help_outline),
            title: "Why can't I see everyone?",
            subtitle: 'See who is sending updates',
            chevron: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DeliveryScreen(circle: _circle))),
          ),
        ],
      ),
    );
  }

  Future<void> _addServer() async {
    await showAddServerSheet(context, circle: _circle);
    await _loadE2ee();
  }

  Widget _privateCard() {
    final CircleE2eeState? st = _e2eeState;
    if (st == null || !_circle.isAdmin) return _deliveryRow();
    return Column(children: <Widget>[_privateCardBody(st), _deliveryRow()]);
  }

  Widget _privateCardBody(CircleE2eeState st) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: DsRowGroup(
        children: <Widget>[
          DsToggleRow(
            icon: st.isPrivate ? Icons.lock : Icons.lock_open,
            title: 'Private circle',
            subtitle: st.isPrivate
                ? (_circle.e2eeServerMember
                    ? 'Old mode: the server can read it'
                    : _circle.serverAssist
                        ? 'On: the server reads members who use it'
                        : 'On: only members can read locations')
                : 'Off: locations are not encrypted for the server',
            info: st.isPrivate
                ? (_circle.e2eeServerMember
                    ? 'OLD TRUSTED-SERVER MODE: the Orbitly server can read this circle (every member allowed it). An admin can upgrade it under Encryption keys > Server processing.'
                    : 'Positions, history, places and events are end-to-end encrypted: only the members can read them, '
                        'except the data of members who use server processing, which the server can read too. '
                        'Each member\'s own setting is under Encryption keys > Server processing. Chat is always end-to-end encrypted.')
                : 'Turning it on encrypts locations so the server cannot read them. Some server features are not available in private circles.',
            infoTitle: 'Private circle',
            value: st.isPrivate,
            onChanged: _e2eeBusy ? null : _togglePrivate,
          ),
          if (st.isPrivate)
            DsListRow(
              key: const Key('circle-add-server'),
              leading: DsListRow.iconTile(context, Icons.dns_outlined),
              title: 'Add server to this circle',
              subtitle: 'Keep history, trips and driving reports',
              info: 'Lets your own server keep history, trips and driving reports for this circle. Takes three taps.',
              chevron: true,
              onTap: _addServer,
            ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadE2ee();
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

  Future<void> _extend(int hours) async {
    Circle? updated;
    final bool ok = await _run(() async {
      updated = await _service.extendCircle(_circle.id, hours);
    }, done: 'Circle extended');
    if (ok && updated != null && mounted) {
      setState(() => _circle = _circle.copyWith(expiresAt: updated!.expiresAt));
    }
  }

  Future<void> _endNow() async {
    if (!await _confirm(
        'End ${_circle.name} now?',
        'Everyone stops seeing each other in this circle right away. '
            'This cannot be undone.',
        'End now')) {
      return;
    }
    if (await _run(() => _service.endCircle(_circle.id)) && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Admin sheet for a temporary circle: extend by a preset, or end it now.
  Future<void> _manageLifetime() async {
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final MapEntry<String, int> p in kTempCircleExtensions.entries)
              ListTile(
                leading: const Icon(Icons.more_time),
                title: Text('Extend by ${p.key}'),
                onTap: () => Navigator.of(ctx).pop('extend:${p.value}'),
              ),
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: const Text('End now'),
              onTap: () => Navigator.of(ctx).pop('end'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'end') {
      await _endNow();
    } else {
      await _extend(int.parse(choice.substring(7)));
    }
  }

  Future<void> _newInvite() async {
    CircleInvite? created;
    final bool ok = await _run(() async {
      created = await _service.createInvite(_circle.id);
    }, done: 'Invite code created');
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
        'Join my "${_circle.name}" circle on Orbitly!\n\n'
        '1. Install the Orbitly Android app\n'
        '2. Enter this server: ${ServerConfig.instance.apiBaseUrl}\n'
        '3. Use invite code ${inv.code}',
        subject: 'Join my Orbitly circle',
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
              if (_circle.expiresAt != null) _lifetimeCard(),
              _sharingCard(),
              _privateCard(),
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

  Widget _lifetimeCard() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: DsRowGroup(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                CircleCountdownChip(expiresAt: _circle.expiresAt!),
                const Text('Temporary circle'),
                if (_circle.isAdmin)
                  TextButton.icon(
                    onPressed: _busy ? null : _manageLifetime,
                    icon: const Icon(Icons.timer_outlined),
                    label: const Text('Extend / End now'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
      if (_circle.isAdmin && (_e2eeState?.isPrivate ?? false)) ...<Widget>[
        const SizedBox(height: AppSpace.sm),
        DsPillButton(
          key: const Key('invite-add-server'),
          style: DsPillStyle.tonal,
          onPressed: _busy ? null : _addServer,
          icon: Icons.dns_outlined,
          label: 'Add server to this circle',
        ),
      ],
    ];
  }
}

/// This phone's own encryption key cannot be used, so a Private-circle action
/// that must be signed by it failed. Says why and leads to the repair instead of
/// a dead end. Turning Private OFF is signed by a circle admin's phone key on
/// purpose (the key log shows every phone who did it, and the server can never
/// switch a circle back to readable on its own), so there is no server-side
/// shortcut: repair this phone's key, or switch it off from another admin phone.
Future<void> showPrivateKeyProblem(BuildContext context, CircleException err, {required bool turningOff}) async {
  final bool open = await showDsConfirm(
    context,
    title: "This phone's encryption key can't be used",
    message: '${err.message}\n\n'
        '${turningOff ? 'Turning Private off must be signed by a circle admin\'s phone key. ' : ''}'
        'In Encryption keys you can restore the key with your recovery phrase, link this phone from your other phone, '
        'or create new keys for this phone (the other members then see that your key changed).'
        '${turningOff ? ' Another admin of this circle can also turn Private off from their phone.' : ''}',
    confirmLabel: 'Open Encryption keys',
  );
  if (!open || !context.mounted) return;
  await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const EncryptionKeysScreen()));
}
