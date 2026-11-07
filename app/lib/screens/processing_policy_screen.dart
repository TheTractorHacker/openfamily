import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/lanes_service.dart' show LanesNotReady;
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/processing_widgets.dart';
import 'security_widgets.dart';

/// Circle-wide processing settings. ONLY a circle admin can change them
/// (server-enforced and signed); everybody else sees the same screen read-only
/// with the reason. Nothing here can opt a member in.
class ProcessingPolicyScreen extends StatefulWidget {
  const ProcessingPolicyScreen({super.key, required this.circle, this.controller});
  final Circle circle;
  final ProcessingController? controller;

  @override
  State<ProcessingPolicyScreen> createState() => _ProcessingPolicyScreenState();
}

class _ProcessingPolicyScreenState extends State<ProcessingPolicyScreen> {
  ProcessingController get _c => widget.controller ?? LanesProcessingController.instance;
  ProcessingSnapshot? _s;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _s == null;
      _error = null;
    });
    try {
      final ProcessingSnapshot s = await _c.load(widget.circle.id, force: true);
      if (!mounted) return;
      setState(() {
        _s = s;
        _loading = false;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorText(e);
      });
    }
  }

  Future<void> _apply({required bool assist, required int defaultForNew, required int memberOptOut, required String done}) async {
    setState(() => _busy = true);
    try {
      await _c.setPolicy(widget.circle.id, assist: assist, defaultForNew: defaultForNew, memberOptOut: memberOptOut);
      _say(done);
    } on LanesNotReady catch (e) {
      _say('${e.names.join(', ')} must update the app first.');
    } catch (e) {
      _say(e is StateError ? e.message : errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  void _say(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _toggleAssist(bool on) async {
    final ProcessingSnapshot s = _s!;
    final bool ok = await showDsConfirm(context,
        title: on ? ProcessingCopy.turnOnTitle : ProcessingCopy.turnOffTitle,
        message: on
            ? '${ProcessingCopy.turnOnBody}\n\nDefault shown to new members: ${s.policy.defaultForNew == E2ee.lineServer ? 'Server processing' : 'Phone only'}.'
            : ProcessingCopy.turnOffBody,
        confirmLabel: on ? 'Turn on' : 'Turn off',
        destructive: on);
    if (!ok) return;
    await _apply(
        assist: on,
        defaultForNew: on ? s.policy.defaultForNew : E2ee.linePhone,
        memberOptOut: E2ee.optOutAllowed,
        done: on ? 'Server processing is on. Nobody is opted in until they choose.' : 'Server processing is off');
  }

  Future<void> _setOptOut(int mode) async {
    final ProcessingSnapshot s = _s!;
    if (s.policy.memberOptOut == mode) return;
    if (mode == E2ee.optOutRequiredServer) {
      final bool ok = await showDsConfirm(context,
          title: ProcessingCopy.requiredTitle, message: ProcessingCopy.requiredBody, confirmLabel: 'Require it', destructive: true);
      if (!ok) return;
    }
    await _apply(assist: true, defaultForNew: s.policy.defaultForNew, memberOptOut: mode, done: 'Setting saved');
  }

  Future<void> _setDefault(int lane) async {
    final ProcessingSnapshot s = _s!;
    if (s.policy.defaultForNew == lane) return;
    await _apply(assist: true, defaultForNew: lane, memberOptOut: s.policy.memberOptOut, done: 'Default saved');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Circle processing setting')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _s == null
                ? LoadStateView(error: _error, offline: false, onRetry: _load)
                : _body(_s!),
      ),
    );
  }

  Widget _option(Key key, String title, String subtitle, bool selected, VoidCallback? onTap) => DsListRow(
        key: key,
        leading: DsListRow.iconTile(context, selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        title: title,
        subtitle: subtitle,
        selected: selected,
        onTap: onTap,
      );

  Widget _body(ProcessingSnapshot s) {
    final bool admin = s.iAmAdmin;
    final bool canEdit = admin && !_busy && s.isPrivate && !s.legacy;
    String? blocked;
    if (!s.isPrivate) {
      blocked = 'This is not a Private circle.';
    } else if (s.legacy) {
      blocked = 'This circle is in the old trusted-server mode. Upgrade it first (Server processing > Upgrade this circle).';
    } else if (!s.assistOn && s.notReady.isNotEmpty) {
      blocked = s.notReady.map((String n) => '$n\'s app is out of date and cannot use this yet.').join(' ');
    } else if (!s.assistOn && !s.hasServerKey) {
      blocked = 'This OpenFamily server has no approved server key for this circle. The server operator has to set that up first.';
    }
    final bool canTurnOn = canEdit && (s.assistOn || blocked == null);
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: <Widget>[
        if (!admin)
          const ProcessingNote(noteKey: Key('policy-readonly'), icon: Icons.lock_outline, text: ProcessingCopy.adminOnly),
        if (!admin) const SizedBox(height: AppSpace.lg),
        DsToggleRow(
          key: const Key('policy-assist-switch'),
          icon: Icons.dns_outlined,
          title: 'Server assistance',
          subtitle: s.assistOn
              ? 'On. The server can read data of members who allow it.'
              : 'Off. Every member\'s phone does the processing and nothing is readable by the server.',
          value: s.assistOn,
          onChanged: canTurnOn ? _toggleAssist : null,
        ),
        if (admin && blocked != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(blocked, key: const Key('policy-blocked'), style: AppType.secondary.copyWith(color: AppColors.statusRed)),
          ),
        if (s.assistOn) ...<Widget>[
          const DsSectionHeader('Can members keep data on their phone?', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          DsRowGroup(children: <Widget>[
            _option(const Key('opt-allowed'), 'Yes, members may opt out (default)',
                'Keeping your location on your own phone is the member\'s choice.', s.policy.memberOptOut == E2ee.optOutAllowed,
                canEdit ? () => _setOptOut(E2ee.optOutAllowed) : null),
            _option(const Key('opt-required'), 'No, server processing is required',
                'For circles that need it, for example a parent managing a child\'s phone. New members see this before they join. '
                    'Existing members must consent on their own phone or leave. This applies to child accounts too.',
                s.policy.memberOptOut == E2ee.optOutRequiredServer, canEdit ? () => _setOptOut(E2ee.optOutRequiredServer) : null),
          ]),
          const DsSectionHeader('Default shown to new members', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          DsRowGroup(children: <Widget>[
            _option(const Key('default-phone'), 'Phone only', 'Preselected for people who join.', s.policy.defaultForNew == E2ee.linePhone,
                canEdit ? () => _setDefault(E2ee.linePhone) : null),
            _option(const Key('default-server'), 'Server processing', 'Preselected for people who join. They still have to confirm it themselves.',
                s.policy.defaultForNew == E2ee.lineServer, canEdit ? () => _setDefault(E2ee.lineServer) : null),
          ]),
          const SizedBox(height: AppSpace.sm),
          const Text('A default is only a suggestion. Only a member\'s own phone can put their data on the server; nobody, including admins, can do it for them.',
              style: AppType.secondary),
        ],
        const SizedBox(height: AppSpace.xl),
        const ProcessingNote(
            icon: Icons.info_outline,
            text: 'Every change here is a signed entry in the key log that all members can see. ${ProcessingCopy.operatorCanRead}'),
      ],
    );
  }
}
