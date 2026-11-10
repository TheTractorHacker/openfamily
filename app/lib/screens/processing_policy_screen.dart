import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/lanes_service.dart' show LanesNotReady;
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/add_server_sheet.dart';
import '../widgets/processing_widgets.dart';

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
  ProcessingErrorText? _error;

  /// What failed, so the error state can name the cause (see describeError).

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
        _error = processingErrorText(e);
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
      _say(processingErrorText(e, step: 'The setting was not saved.').message);
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
            ? '${ProcessingCopy.turnOnBody}\n\nDefault for members: Server processing. You can change it to "Phone only" afterwards.'
            : ProcessingCopy.turnOffBody,
        confirmLabel: on ? 'Turn on' : 'Turn off',
        destructive: on);
    if (!ok) return;
    // Section 24: turning it on makes the server the default for members (their own phones sign it, with a
    // notice); turning it off keeps whatever default the admin had chosen.
    await _apply(
        assist: on,
        defaultForNew: on ? E2ee.lineServer : s.policy.defaultForNew,
        memberOptOut: E2ee.optOutAllowed,
        done: on
            ? 'Server processing is on. Each member\'s own phone switches it on for them, with a notice; anyone can opt out.'
            : 'Server processing is off');
  }

  Future<void> _setUpServerKey() async {
    await showAddServerSheet(context, circle: widget.circle, controller: _c);
    if (mounted) await _load();
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
                ? DsErrorState(icon: _error!.icon, title: _error!.title, message: _error!.message, onRetry: _load)
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
    final bool canEdit = admin && !_busy && s.isPrivate && !s.legacy && !s.unconfirmed;
    String? blocked;
    if (s.unconfirmed) {
      blocked = 'The current settings could not be confirmed right now, so they cannot be changed. Pull down on the previous screen to try again.';
    } else if (!s.isPrivate) {
      blocked = 'This is not a Private circle.';
    } else if (s.legacy) {
      blocked = 'This circle is in the old trusted-server mode. Upgrade it first (Server processing > Upgrade this circle).';
    } else if (!s.assistOn && s.notReady.isNotEmpty) {
      blocked = s.notReady.map((String n) => '$n\'s app is out of date and cannot use this yet.').join(' ');
    } else if (!s.assistOn && !s.hasServerKey) {
      blocked = 'This Orbitly server has no approved server key for this circle yet. Tap "Set up the server key" below: if you run this server you can finish it from here.';
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
        if (admin && !s.assistOn && s.isPrivate && !s.legacy && s.notReady.isEmpty && !s.hasServerKey)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.md),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('policy-setup-server'),
                onPressed: _busy ? null : _setUpServerKey,
                icon: const Icon(Icons.vpn_key_outlined),
                label: const Text('Set up the server key'),
              ),
            ),
          ),
        if (s.assistOn) ...<Widget>[
          const DsSectionHeader('Can members keep data on their phone?', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          DsRowGroup(children: <Widget>[
            _option(const Key('opt-allowed'), 'Yes, members may opt out (default)',
                'Keeping your location on your own phone is the member\'s choice. They switch it off in Settings > Server processing.',
                s.policy.memberOptOut == E2ee.optOutAllowed, canEdit ? () => _setOptOut(E2ee.optOutAllowed) : null),
            _option(const Key('opt-required'), 'No, server processing is required',
                'Everyone\'s phone sends its location to your Orbitly server for processing. Members cannot turn it off. Each '
                    'member\'s phone switches over by itself, without a question; a phone that has not switched over yet cannot send positions until it has. Applies to child accounts too.',
                s.policy.memberOptOut == E2ee.optOutRequiredServer, canEdit ? () => _setOptOut(E2ee.optOutRequiredServer) : null),
          ]),
          const DsSectionHeader('Default for members', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          DsRowGroup(children: <Widget>[
            _option(const Key('default-server'), 'Server processing (recommended)',
                'Each member\'s own phone switches it on the next time they open the app and shows a notice. Anyone can switch it off.',
                s.policy.defaultForNew == E2ee.lineServer, canEdit ? () => _setDefault(E2ee.lineServer) : null),
            _option(const Key('default-phone'), 'Phone only', 'Members are asked. Nothing reaches the server until they confirm it themselves.',
                s.policy.defaultForNew == E2ee.linePhone, canEdit ? () => _setDefault(E2ee.linePhone) : null),
          ]),
          const SizedBox(height: AppSpace.sm),
          const Text(
              'Only a member\'s own phone signs where their data is processed. With "Server processing" as the default their phone '
              'does it for them, shows it, and they can switch it off at any time (unless the server\'s administrator has turned '
              'automatic switching off; then members are asked). When server processing is required, every member\'s phone '
              'signs it by itself and members cannot switch it off.',
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
