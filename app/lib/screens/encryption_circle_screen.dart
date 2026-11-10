import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_trust.dart';
import '../services/e2ee/lanes_store.dart' show LaneStatus;
import '../services/e2ee/private_runtime.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/trusted_server_prompt.dart';
import 'encryption_widgets.dart';
import 'member_safety_screen.dart';
import 'security_widgets.dart';
import 'circle_detail_screen.dart';
import 'processing_screen.dart';
import 'viewer_approval_screen.dart';

/// Asks for the password (and a 2FA code if the person uses one) before an
/// owner-approval action. Null when cancelled.
Future<({String password, String totp})?> askOwnerStepUp(BuildContext context,
        {required String title, required String message, required String confirmLabel}) =>
    showDialog<({String password, String totp})>(
      context: context,
      builder: (_) => _OwnerStepUpDialog(title: title, message: message, confirmLabel: confirmLabel),
    );

class _OwnerStepUpDialog extends StatefulWidget {
  const _OwnerStepUpDialog({required this.title, required this.message, required this.confirmLabel});
  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_OwnerStepUpDialog> createState() => _OwnerStepUpDialogState();
}

class _OwnerStepUpDialogState extends State<_OwnerStepUpDialog> {
  final TextEditingController _pw = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _pw.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(widget.message),
          const SizedBox(height: AppSpace.md),
          TextField(
            key: const Key('owner-stepup-password'),
            controller: _pw,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Your password'),
          ),
          TextField(
            key: const Key('owner-stepup-totp'),
            controller: _code,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Two-factor code (only if you use one)'),
          ),
        ]),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_pw.text.isEmpty) return;
            Navigator.of(context).pop((password: _pw.text, totp: _code.text.trim()));
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// One circle's encryption: status, new-key duty, requests from new/replacement
/// keys ("Waiting for approval"), and every member's verification state.
/// This phone's VERIFIED lane facts for one circle (null when unknown): what the "Server processing" row says.
typedef LaneFactsReader = Future<({LaneStatus status, bool assist})?> Function(String circleId);

Future<({LaneStatus status, bool assist})?> _storedLaneFacts(String circleId) async {
  final PrivateRuntime? rt = PrivateRuntime.existing; // never creates a runtime (tests, signed out)
  if (rt == null) return null;
  return (status: await rt.lanesService.store.status(circleId), assist: (await rt.lanesService.store.policy(circleId)).assist);
}

/// The real state for the "Server processing" row, from the lane facts this phone verified.
String processingRowSubtitle({required bool legacy, ({LaneStatus status, bool assist})? facts}) {
  if (legacy) return 'Old mode: the server can read it';
  if (facts == null) return 'See where your data is processed';
  switch (facts.status) {
    case LaneStatus.serverAssisted:
      return 'On for you';
    case LaneStatus.serverPending:
      return 'Switching on for you';
    case LaneStatus.verificationFailed:
      return 'Phone only (could not be confirmed)';
    case LaneStatus.phoneOnly:
      return facts.assist ? 'Phone only for you (you can switch it on)' : 'Phone only (off for this circle)';
  }
}

class EncryptionCircleScreen extends StatefulWidget {
  const EncryptionCircleScreen(
      {super.key, required this.circle, this.service, this.promptStore = const TrustedServerPromptStore(), this.laneFacts = _storedLaneFacts});
  final Circle circle;
  final E2eeService? service;
  final TrustedServerPromptStore promptStore;
  final LaneFactsReader laneFacts;

  @override
  State<EncryptionCircleScreen> createState() => _EncryptionCircleScreenState();
}

class _EncryptionCircleScreenState extends State<EncryptionCircleScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  CircleE2eeState? _state;
  PendingReport _pending = const PendingReport();
  Map<String, TrustAssessment> _trust = <String, TrustAssessment>{};
  String _me = '';
  List<E2eeAlarm> _laneAlarms = <E2eeAlarm>[];
  ({LaneStatus status, bool assist})? _laneFacts;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// What failed, so the error state can name the cause (see describeError).
  Object? _errorCause;
  bool _showTrustPrompt = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorCause = null;
    });
    try {
      final LocalIdentity? id = await _svc.identity();
      final CircleE2eeState st = await _svc.api.circleState(widget.circle.id);
      PendingReport p = const PendingReport();
      if (st.isPrivate && id != null) {
        await _svc.syncCircleKeys(widget.circle.id);
        p = await _svc.processPending(widget.circle.id);
      }
      final Map<String, TrustAssessment> t = <String, TrustAssessment>{};
      for (final CircleE2eeMember m in st.members) {
        t[m.userId] = await _svc.trust.assess(m.userId, m.devices.map((DeviceKey d) => d.fingerprint));
      }
      ({LaneStatus status, bool assist})? facts;
      if (st.isPrivate) {
        try {
          facts = await widget.laneFacts(widget.circle.id);
        } catch (_) {}
      }
      List<E2eeAlarm> la = <E2eeAlarm>[];
      try {
        la = (await _svc.laneAlarmList()).where((E2eeAlarm a) => a.circleId == widget.circle.id).toList();
      } catch (_) {}
      // Admin recommends trusting the server, its key is pinned, and this person
      // has not allowed it (and has not dismissed the notice). Never nags again.
      bool prompt = false;
      if (st.isPrivate && !widget.circle.e2eeServerMember) {
        try {
          if (await _svc.api.trustedServerDefault()) {
            final ServerMemberState ss = await _svc.api.serverMemberState(widget.circle.id);
            prompt = ss.enabled && ss.device != null && !ss.myConsent && !await widget.promptStore.dismissed(widget.circle.id);
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _laneAlarms = la;
        _laneFacts = facts;
        _showTrustPrompt = prompt;
        _state = st;
        _pending = p;
        _trust = t;
        _me = id?.userId ?? '';
        _loading = false;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorText(e);
        _errorCause = e;
      });
    }
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _isCreator => _state?.createdBy != null && _state!.createdBy == _me;

  Future<void> _openMembers() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => CircleDetailScreen(circle: widget.circle)));
    if (mounted) _load();
  }

  /// Turns the owner-approval rule on (creator, with password) or off (any admin).
  Future<void> _setOwnerApproval(bool on) async {
    if (!on) {
      final bool ok = await showDsConfirm(context,
          title: 'Turn off owner approval?',
          message: 'A new phone of the owner will need another admin to approve it again.',
          confirmLabel: 'Turn off');
      if (ok) await _run(() => _svc.setOwnerApproval(widget.circle.id, false), 'Owner approval is off');
      return;
    }
    final auth = await askOwnerStepUp(context,
        title: 'Turn on owner approval?',
        message: 'You created this circle, so you could then approve your own new phone without a second admin. '
            'Everyone in the circle is told when you do. Someone who steals your password could do the same, '
            'so also keep your recovery phrase and add a second admin.',
        confirmLabel: 'Turn on');
    if (auth == null) return;
    await _run(() => _svc.setOwnerApproval(widget.circle.id, true, password: auth.password, totpCode: auth.totp), 'Owner approval is on');
  }

  Future<void> _approveAsOwner(DeviceKey key) async {
    final auth = await askOwnerStepUp(context,
        title: 'Approve this phone as owner?',
        message: 'Your new key ${key.short} will be approved without a second admin. The other members are told.',
        confirmLabel: 'Approve');
    if (auth == null) return;
    await _run(() => _svc.approveDevice(widget.circle.id, key, password: auth.password, totpCode: auth.totp), 'This phone is approved');
  }

  /// Shows who is asking, for which circles, and the safety number; returns true
  /// only when the user states the numbers match.
  Future<bool> _confirmRequest(PendingItem item, {required String action}) async {
    final r = await _svc.safetyWith(item.key.userId);
    // Circles both of us are in: the only ones this request can ever affect.
    final String circles = widget.circle.name;
    if (!mounted) return false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('${item.key.userName ?? 'A member'} is requesting a key'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('Reason: ${item.result.reason}.'),
            const SizedBox(height: AppSpace.sm),
            Text('Circle affected: $circles (only circles you both belong to are ever shared).'),
            const SizedBox(height: AppSpace.sm),
            Text('New key: ${item.key.short}'),
            const SizedBox(height: AppSpace.md),
            const Text('Safety number. Ask them in person, or on a call you trust, to read theirs and compare:'),
            const SizedBox(height: AppSpace.sm),
            DigitBlock(digits: r.number, label: 'Safety number'),
            const SizedBox(height: AppSpace.sm),
            const Text('Only continue if every group matches. If it does not, someone may be impersonating them.'),
          ]),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Does not match')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.circle.name, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? (_errorCause != null
                    ? LoadStateView.forError(_errorCause!, onRetry: _load)
                    : LoadStateView(error: _error, offline: false, onRetry: _load))
                : _body(_state!),
      ),
    );
  }

  /// This phone's own key, waiting for approval: plain words and the right action.
  Widget _ownWaitingCard(CircleE2eeState st, PendingItem p) {
    final OwnKeyApproval a = E2eeService.ownKeyApproval(st, _me);
    final String names = a.otherAdminNames.isEmpty ? 'another admin' : a.otherAdminNames.join(' or ');
    final String text = switch (a.action) {
      OwnKeyAction.approveAsOwner => 'You created this circle, so you can approve it yourself. You\'ll confirm with your password.',
      OwnKeyAction.askOtherAdmin => 'Ask $names to open this circle in Encryption keys and approve it.',
      OwnKeyAction.soleAdminCanEnable =>
        'You\'re the only admin. Make another member an admin so they can approve this phone, or turn on owner approval for this circle.',
      OwnKeyAction.soleAdmin => 'You\'re the only admin. Make another member an admin so they can approve this phone.',
    };
    return Container(
      key: Key('own-waiting-${p.key.deviceId}'),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          const Icon(Icons.hourglass_top),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: Text('Waiting for approval', style: AppType.body.copyWith(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: AppSpace.xs),
        Text(text, style: AppType.secondary),
        const SizedBox(height: AppSpace.sm),
        Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: <Widget>[
          if (a.action == OwnKeyAction.approveAsOwner)
            DsPillButton(
              key: const Key('approve-as-owner'),
              label: 'Approve as owner',
              icon: Icons.verified_user_outlined,
              onPressed: _busy ? null : () => _approveAsOwner(p.key),
            ),
          if (a.action == OwnKeyAction.soleAdminCanEnable)
            DsPillButton(
              key: const Key('enable-owner-approval'),
              label: 'Turn on owner approval',
              icon: Icons.admin_panel_settings_outlined,
              onPressed: _busy ? null : () => _setOwnerApproval(true),
            ),
          if (a.action == OwnKeyAction.soleAdminCanEnable || a.action == OwnKeyAction.soleAdmin)
            DsPillButton(
              key: const Key('open-members'),
              label: 'Members',
              icon: Icons.group_outlined,
              style: DsPillStyle.outlined,
              onPressed: _busy ? null : _openMembers,
            ),
        ]),
      ]),
    );
  }

  Widget _body(CircleE2eeState st) {
    final bool admin = widget.circle.isAdmin;
    final List<PendingItem> ownWaiting = _pending.waiting.where((PendingItem p) => p.key.userId == _me).toList();
    final List<PendingItem> otherWaiting = _pending.waiting.where((PendingItem p) => p.key.userId != _me).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          for (final E2eeAlarm a in _laneAlarms)
            Padding(padding: const EdgeInsets.only(bottom: AppSpace.md), child: AlarmBanner(key: Key('lane-alarm-${a.circleId}'), alarm: a)),
          Row(children: <Widget>[
            Expanded(child: Text(st.isPrivate ? 'Private circle' : 'Normal circle', style: AppType.headline)),
            if (st.isPrivate)
              InfoHint(
                title: 'Private circle',
                body: (widget.circle.e2eeServerMember
                        ? 'The circle key is held by members\' phones AND by your Orbitly server (old trusted-server mode): the server can read this circle. An admin can upgrade it under Server processing.'
                        : 'The circle key is held only by members\' phones. The server cannot read what is sealed for phones only. Members who allow server processing under "Server processing" can be read by the server.') +
                    '\n\nAdvanced: key epoch ${st.epoch}.',
              ),
          ]),
          const SizedBox(height: AppSpace.xs),
          Text(
            st.isPrivate
                ? (widget.circle.e2eeServerMember ? 'Old mode: the server can read this circle.' : 'Only members can read locations here.')
                : 'Not encrypted. Admins can turn on "Private circle".',
            style: AppType.secondary,
          ),
          if (_showTrustPrompt) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            TrustedServerPrompt(
              onOpen: () async {
                await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                    builder: (_) => ProcessingScreen(circle: widget.circle, service: _svc)));
                if (mounted) _load();
              },
              onDismiss: () async {
                await widget.promptStore.dismiss(widget.circle.id);
                if (mounted) setState(() => _showTrustPrompt = false);
              },
            ),
          ],
          if (st.isPrivate && st.rekeyRequired) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            AlarmBanner(
              alarm: E2eeAlarm(AlarmKind.keyChanged, 'A new circle key is needed',
                  'A member left or a key was revoked. ${!admin ? 'A circle admin has to publish a new key.' : ownWaiting.isNotEmpty ? 'Get this phone approved first (see below), then publish a new key.' : 'Publish a new key so those who left cannot read what comes next.'}'),
            ),
            if (admin)
              DsPillButton(
                key: const Key('publish-new-key'),
                label: 'Publish new key',
                icon: Icons.vpn_key,
                onPressed: _busy || ownWaiting.isNotEmpty ? null : () => _run(() async => _svc.bumpEpoch(widget.circle.id), 'New key published'),
              ),
          ],
          if (ownWaiting.isNotEmpty) ...<Widget>[
            const DsSectionHeader('Your new key', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            for (final PendingItem p in ownWaiting) _ownWaitingCard(st, p),
          ],
          if (_pending.needConfirm.isNotEmpty || otherWaiting.isNotEmpty) ...<Widget>[
            const DsSectionHeader('Key requests', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            DsRowGroup(children: <Widget>[
              for (final PendingItem p in _pending.needConfirm)
                DsListRow(
                  leading: DsListRow.iconTile(context, Icons.key, color: const Color(0xFFD97706)),
                  title: p.key.userName ?? 'A member',
                  subtitle: '${p.result.reason}. Compare safety numbers first.',
                  chevron: true,
                  onTap: _busy
                      ? null
                      : () async {
                          if (await _confirmRequest(p, action: 'It matches: share key')) {
                            await _run(() => _svc.confirmWrap(widget.circle.id, p.key, markVerified: true), 'Key shared');
                          }
                        },
                ),
              for (final PendingItem p in otherWaiting)
                DsListRow(
                  leading: DsListRow.iconTile(context, Icons.hourglass_top),
                  title: '${p.key.userName ?? 'A member'}: new phone to approve',
                  subtitle: admin ? 'Compare safety numbers, then approve it.' : 'A circle admin must approve it.',
                  chevron: admin,
                  onTap: (!admin || _busy)
                      ? null
                      : () async {
                          if (await _confirmRequest(p, action: 'It matches: approve')) {
                            await _run(() => _svc.approveDevice(widget.circle.id, p.key), 'Approved for this circle');
                          }
                        },
                ),
            ]),
          ],
          if (st.isPrivate && admin && st.createdBy != null) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            DsRowGroup(children: <Widget>[
              DsToggleRow(
                key: const Key('owner-approval-toggle'),
                icon: Icons.admin_panel_settings_outlined,
                title: 'Owner approval',
                subtitle: st.ownerApproval ? 'The owner can approve their own new phone' : 'A new phone of an admin needs another admin',
                info: 'Lets the person who created this circle approve their own replacement phone without a second admin, '
                    'after entering their password. Members are told each time. Only the creator can turn it on; any admin can turn it off.',
                value: st.ownerApproval,
                onChanged: _busy || (!st.ownerApproval && !_isCreator) ? null : _setOwnerApproval,
              ),
            ]),
          ],
          if (st.isPrivate) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            DsRowGroup(children: <Widget>[
              DsListRow(
                leading: DsListRow.iconTile(context, Icons.devices_other),
                title: 'Approve a viewer or bridge',
                subtitle: 'Web viewer or Dawarich bridge',
                chevron: true,
                onTap: _busy
                    ? null
                    : () async {
                        await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                            builder: (_) => ViewerApprovalScreen(circle: widget.circle, service: _svc)));
                        if (mounted) _load();
                      },
              ),
              DsListRow(
                key: const Key('processing-row'),
                leading: DsListRow.iconTile(context, Icons.dns_outlined),
                title: 'Server processing',
                subtitle: processingRowSubtitle(legacy: widget.circle.e2eeServerMember, facts: _laneFacts),
                info: 'Where your data is processed. Includes "Don\'t send my data to the server".',
                chevron: true,
                onTap: _busy
                    ? null
                    : () async {
                        await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                            builder: (_) => ProcessingScreen(circle: widget.circle, service: _svc)));
                        if (mounted) _load();
                      },
              ),
            ]),
          ],
          const DsSectionHeader('Members', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          DsRowGroup(children: <Widget>[
            for (final CircleE2eeMember m in st.members)
              DsListRow(
                leading: DsListRow.iconTile(context, Icons.person_outline),
                title: m.userId == _me ? '${m.name} (you)' : m.name,
                subtitle: m.devices.isEmpty
                    ? 'No key yet'
                    : m.devices.any((DeviceKey d) => d.approved == false)
                        ? 'New phone to approve'
                        : m.devices.any((DeviceKey d) => d.ownerApproved)
                            ? 'Approved by the owner without a second admin'
                            : ((_trust[m.userId]?.level ?? TrustLevel.unseen) == TrustLevel.verified ? 'Verified' : 'Ready'),
                info: m.devices.isEmpty ? null : 'Advanced: ${m.devices.length} key${m.devices.length == 1 ? '' : 's'} registered for ${m.name}.',
                trailing: m.userId == _me ? null : VerifiedBadge(level: _trust[m.userId]?.level ?? TrustLevel.unseen),
                chevron: m.userId != _me && m.devices.isNotEmpty,
                onTap: (m.userId == _me || m.devices.isEmpty)
                    ? null
                    : () async {
                        await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                            builder: (_) => MemberSafetyScreen(
                                userId: m.userId,
                                name: m.name,
                                service: _svc,
                                ownerApprovedDeviceIds: <String>{for (final DeviceKey d in m.devices) if (d.ownerApproved) d.deviceId})));
                        if (mounted) _load();
                      },
              ),
          ]),
        ],
      ),
    );
  }
}
