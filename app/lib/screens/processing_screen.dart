import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/lanes_store.dart';
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/processing_widgets.dart';
import 'legacy_upgrade_screen.dart';
import 'processing_policy_screen.dart';
import 'security_widgets.dart';
import 'trusted_server_screen.dart';

/// Circle > Encryption keys > this circle > Server processing.
///
/// Two layers (PRIVACY_PROCESSING 10.2): the circle admin decides whether server
/// processing is AVAILABLE; every member decides for their OWN data. Nobody can
/// opt another member in. Everything shown here was verified on this phone
/// against the signed key log.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.circle, this.controller, this.service});
  final Circle circle;
  final ProcessingController? controller;

  /// Only used to open the old trusted-server screen of a legacy circle.
  final E2eeService? service;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
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

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = _s == null;
      _error = null;
    });
    try {
      final ProcessingSnapshot s = await _c.load(widget.circle.id, force: force);
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

  void _say(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      _say(done);
    } catch (e) {
      _say(e is StateError ? e.message : errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load(force: true);
  }

  // ------------------------------------------------------------- my choice

  Future<void> _optOut() async {
    bool del = true;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => AlertDialog(
          title: const Text(ProcessingCopy.optOutTitle),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text(ProcessingCopy.optOutBody),
              CheckboxListTile(
                key: const Key('optout-delete-copies'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: del,
                onChanged: (bool? v) => set(() => del = v ?? false),
                title: const Text(ProcessingCopy.deleteCopiesLabel),
              ),
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            FilledButton(key: const Key('optout-confirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Keep on my phone')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(() => _c.setMyLane(widget.circle.id, E2ee.linePhone, deleteCopies: del), 'Your data now stays on your phone');
  }

  Future<void> _optIn() async {
    final ProcessingSnapshot s = _s!;
    final String? fp = s.serverKeyFingerprint;
    if (fp == null) return;
    final bool ok = await showDsConfirm(context,
        title: ProcessingCopy.optInTitle,
        message: '${ProcessingCopy.optInBody}\n\nServer key to compare with the one your admin or server operator sees: '
            '${s.serverKeyShort}\n${s.serverKeyDigits}',
        confirmLabel: 'Allow',
        destructive: true);
    if (!ok) return;
    await _run(() => _c.setMyLane(widget.circle.id, E2ee.lineServer, confirmServerFingerprintHex: fp), 'You allowed server processing');
  }

  Future<void> _chooseUndecided(int lane) => lane == E2ee.lineServer ? _optIn() : _optOut();

  Future<void> _delete({required bool whole}) async {
    final bool ok = await showDsConfirm(context,
        title: whole ? 'Delete all server copies of this circle?' : 'Delete my copies from the server?',
        message: 'The server deletes the readable positions it holds for ${whole ? 'every member of this circle' : 'you'}. '
            'Sealed data other members still need is not touched. Backups and anything already exported cannot be deleted.',
        confirmLabel: 'Delete copies',
        destructive: true);
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final int n = await _c.deleteCopies(widget.circle.id, wholeCircle: whole);
      _say('Deleted $n server copies');
    } catch (e) {
      _say(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server processing')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _s == null
                ? LoadStateView(error: _error, offline: false, onRetry: _load)
                : _body(_s!),
      ),
    );
  }

  Widget _body(ProcessingSnapshot s) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ProcessingMember? me = s.me;
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          Text(widget.circle.name, style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          if (!s.isPrivate)
            const ProcessingNote(
                noteKey: Key('proc-not-private'),
                icon: Icons.lock_open,
                text: 'This is a normal circle, not a Private circle. Your position is sent to the server in readable form. '
                    'Turn on "Private circle" in the circle settings (admins only) to use end-to-end encryption.')
          else ...<Widget>[
            _statusCard(s),
            if (s.legacy) ...<Widget>[const SizedBox(height: AppSpace.lg), _legacyCard(s)],
            if (s.status == LaneStatus.verificationFailed)
              const Padding(
                padding: EdgeInsets.only(top: AppSpace.lg),
                child: ProcessingNote(
                    noteKey: Key('proc-verification-failed'),
                    icon: Icons.warning_amber,
                    color: AppColors.statusRed,
                    text: 'The key log or the processing records did not verify. Your phone treats this circle as phone only until they do.'),
              ),
            const DsSectionHeader('Circle setting', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            DsRowGroup(children: <Widget>[
              DsListRow(
                key: const Key('proc-open-policy'),
                leading: DsListRow.iconTile(context, Icons.admin_panel_settings_outlined),
                title: s.iAmAdmin ? 'Server processing for this circle' : 'How this circle is set up',
                subtitle: _policyLine(s) + (s.iAmAdmin ? '' : ' Set by the circle admin.'),
                chevron: true,
                onTap: () async {
                  await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                      builder: (_) => ProcessingPolicyScreen(circle: widget.circle, controller: _c)));
                  if (mounted) _load(force: true);
                },
              ),
            ]),
            if (!s.iAmAdmin)
              const Padding(
                padding: EdgeInsets.only(top: AppSpace.sm),
                child: Text(ProcessingCopy.adminOnly, key: Key('proc-admin-only'), style: AppType.secondary),
              ),
            const DsSectionHeader('My data', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            ..._myChoice(s, me),
            const DsSectionHeader('Members', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            DsRowGroup(children: <Widget>[
              for (final ProcessingMember m in s.members)
                DsListRow(
                  key: Key('member-${m.userId}'),
                  leading: DsListRow.iconTile(context, Icons.person_outline),
                  title: m.isMe ? '${m.name} (you)' : m.name,
                  subtitle: m.serverAssisted
                      ? 'Allowed server processing'
                      : (s.assistOn && !m.verified ? 'No choice made yet, phone only' : 'Keeps data on their phone'),
                  trailing: LaneChip(server: m.serverAssisted),
                ),
            ]),
            if (s.assistOn || s.serverCount > 0) ...<Widget>[
              const DsSectionHeader('Delete server copies', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
              Text(
                'Copies the server made while you allowed it stay until deleted. Backups and anything already exported cannot be deleted.',
                style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.sm),
              DsPillButton(
                key: const Key('delete-mine'),
                label: 'Delete my copies',
                style: DsPillStyle.outlined,
                icon: Icons.delete_outline,
                onPressed: _busy ? null : () => _delete(whole: false),
              ),
              if (s.iAmAdmin) ...<Widget>[
                const SizedBox(height: AppSpace.sm),
                DsPillButton(
                  key: const Key('delete-all'),
                  label: 'Delete all copies of this circle',
                  style: DsPillStyle.danger,
                  icon: Icons.delete_forever_outlined,
                  onPressed: _busy ? null : () => _delete(whole: true),
                ),
              ],
            ],
            const SizedBox(height: AppSpace.xl),
            const ProcessingNote(
                noteKey: Key('proc-footnote'),
                icon: Icons.info_outline,
                text: '${ProcessingCopy.operatorCanRead} ${ProcessingCopy.metadata} ${ProcessingCopy.multiCircle}'),
          ],
        ],
      ),
    );
  }

  String _policyLine(ProcessingSnapshot s) {
    if (!s.assistOn) return 'Off. Everyone\'s phone does the processing.';
    return s.required
        ? 'On, and required: members must allow it or leave.'
        : 'On. Each member chooses for their own data (${s.serverCount} of ${s.members.length} use the server).';
  }

  Widget _statusCard(ProcessingSnapshot s) {
    final (IconData icon, Color color, String title, String sub) = !s.assistOn
        ? (Icons.smartphone, AppColors.statusGreen, 'Phones only', 'The server cannot read this circle. Phones do the processing.')
        : (
            Icons.dns_outlined,
            AppColors.statusOrange,
            'Server-assisted (${s.serverCount} of ${s.members.length} members)',
            'The server can read the data of members who allowed it. The others keep their data on their phone.'
          );
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = dark ? Color.lerp(color, Colors.white, 0.45)! : Color.lerp(color, Colors.black, 0.35)!;
    return Semantics(
      container: true,
      label: 'Status: $title. $sub',
      child: Container(
        key: const Key('proc-status-card'),
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Row(children: <Widget>[
          CircleAvatar(radius: 22, backgroundColor: color.withValues(alpha: 0.25), child: Icon(icon, color: fg)),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, key: const Key('proc-status-title'), style: AppType.headline.copyWith(color: fg)),
              Text(sub, style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurface)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _legacyCard(ProcessingSnapshot s) {
    return Container(
      key: const Key('proc-legacy-card'),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.statusOrange.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text('Old trusted-server mode', style: AppType.headline),
        const SizedBox(height: AppSpace.xs),
        const Text(
            'This circle still uses the old setup: the server can read it only while every member has allowed it, and it holds '
            'the circle key. The new setup lets each member choose for themselves.',
            style: AppType.secondary),
        const SizedBox(height: AppSpace.md),
        if (s.iAmAdmin)
          DsPillButton(
            key: const Key('legacy-open-upgrade'),
            label: 'Upgrade this circle',
            icon: Icons.upgrade,
            onPressed: _busy
                ? null
                : () async {
                    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                        builder: (_) => LegacyUpgradeScreen(circle: widget.circle, controller: _c)));
                    if (mounted) _load(force: true);
                  },
          )
        else
          const Text('A circle admin can upgrade it. Until then the old rules apply.', key: Key('legacy-member-note'), style: AppType.secondary),
        const SizedBox(height: AppSpace.sm),
        DsPillButton(
          key: const Key('legacy-open-old'),
          label: 'Old trusted-server settings',
          style: DsPillStyle.outlined,
          onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(
              builder: (_) => TrustedServerScreen(circle: widget.circle, service: widget.service))),
        ),
      ]),
    );
  }

  List<Widget> _myChoice(ProcessingSnapshot s, ProcessingMember? me) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool mine = me?.serverAssisted ?? false;
    final bool undecided = s.assistOn && me != null && !me.verified && s.status != LaneStatus.consentRequired;
    String? why;
    if (!s.assistOn) {
      why = 'Server processing is off for this circle, so your phone does the processing.';
    } else if (s.legacy) {
      why = 'This circle is in the old trusted-server mode. Use the old settings above until an admin upgrades it.';
    } else if (!s.hasServerKey && !mine) {
      why = 'This server has no approved server key for this circle yet, so server processing cannot be chosen.';
    } else if (s.required && mine) {
      why = 'This circle requires server processing. You can only keep your data on your phone by leaving the circle.';
    }
    final bool canToggle = why == null && !_busy;
    return <Widget>[
      if (s.status == LaneStatus.consentRequired)
        Container(
          key: const Key('proc-consent-required'),
          margin: const EdgeInsets.only(bottom: AppSpace.md),
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: AppColors.statusOrange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.statusOrange.withValues(alpha: 0.55)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('This circle requires server processing', style: AppType.headline),
            const SizedBox(height: AppSpace.xs),
            const Text(
                'Your phone sends nothing to this circle (except help requests) until you give your own consent. '
                'Or you can leave the circle.',
                style: AppType.secondary),
            const SizedBox(height: AppSpace.md),
            DsPillButton(
                key: const Key('proc-consent'),
                label: 'Review and consent',
                icon: Icons.lock_open,
                onPressed: _busy || !s.hasServerKey ? null : _optIn),
          ]),
        ),
      if (undecided)
        Container(
          key: const Key('proc-choose'),
          margin: const EdgeInsets.only(bottom: AppSpace.md),
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('Choose where your data is processed', style: AppType.headline),
            const SizedBox(height: AppSpace.xs),
            Text(
                'Until you choose, your phone does the processing. The admin suggests '
                '"${s.policy.defaultForNew == E2ee.lineServer ? 'Server processing' : 'Phone only'}" for new members. '
                'That is only a suggestion: nothing is shared with the server unless you confirm it yourself.',
                key: const Key('proc-default-hint'),
                style: AppType.secondary),
            const SizedBox(height: AppSpace.md),
            Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: <Widget>[
              DsPillButton(
                key: const Key('choose-server'),
                label: 'Server processing',
                style: s.policy.defaultForNew == E2ee.lineServer ? DsPillStyle.filled : DsPillStyle.outlined,
                onPressed: _busy || !s.hasServerKey ? null : () => _chooseUndecided(E2ee.lineServer),
              ),
              DsPillButton(
                key: const Key('choose-phone'),
                label: 'Phone only',
                style: s.policy.defaultForNew == E2ee.linePhone ? DsPillStyle.filled : DsPillStyle.outlined,
                onPressed: _busy ? null : () => _chooseUndecided(E2ee.linePhone),
              ),
            ]),
          ]),
        ),
      DsToggleRow(
        key: const Key('my-lane-switch'),
        icon: Icons.dns_outlined,
        title: 'Let the server process my data',
        subtitle: why ??
            (mine
                ? 'On. The server can read your location, trips and driving data. Switch off to keep them on your phone ("Don\'t send my data to the server").'
                : 'Off. Your phone does the processing; end-to-end encryption between phones continues.'),
        value: mine,
        onChanged: canToggle && me != null
            ? (bool v) => v ? _optIn() : _optOut()
            : null,
      ),
      if (!mine && s.assistOn)
        const Padding(
          padding: EdgeInsets.only(top: AppSpace.sm),
          child: Text(ProcessingCopy.phoneWorkNote, key: Key('proc-phone-note'), style: AppType.secondary),
        ),
    ];
  }
}
