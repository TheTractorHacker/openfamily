import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/lanes_store.dart';
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/processing_widgets.dart';
import '../widgets/server_prompts.dart' show remindMessageText;
import 'legacy_upgrade_screen.dart';
import 'processing_policy_screen.dart';
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
  ProcessingErrorText? _error;

  /// What failed, so the error state can name the cause (see describeError).

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
        _error = processingErrorText(e);
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
      _say(processingErrorText(e, step: 'That did not go through.').message);
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
      _say(processingErrorText(e, step: 'The copies could not be deleted.').message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ build

  /// Circle admin: who is not on the server yet. When the admin requires server processing nobody has to be asked:
  /// those members are "catching up" (their phone signs by itself). Otherwise the message to send them (section 23).
  List<Widget> _notYetOnServer(ProcessingSnapshot s) {
    final List<ProcessingMember> rest = <ProcessingMember>[for (final ProcessingMember m in s.members) if (!m.serverAssisted) m];
    if (s.required) {
      return <Widget>[
        const DsSectionHeader('Still catching up'),
        DsRowGroup(children: <Widget>[
          for (final ProcessingMember m in rest)
            DsListRow(
              key: Key('catching-up-${m.userId}'),
              leading: DsListRow.iconTile(context, Icons.sync, decorative: true),
              title: m.isMe ? '${m.name} (you)' : m.name,
              subtitle: s.notReady.contains(m.name) ? 'Needs to update the app first' : 'Phone is switching over',
              info: s.notReady.contains(m.name) ? null : ProcessingCopy.catchingUpInfo,
              infoTitle: 'Catching up',
            ),
        ]),
      ];
    }
    final double inset = DsRowScope.insetFor(context);
    return <Widget>[
      const DsSectionHeader('Members not yet on the server'),
      DsRowGroup(children: <Widget>[
        for (final ProcessingMember m in rest)
          DsListRow(
            key: Key('not-on-server-${m.userId}'),
            leading: DsListRow.iconTile(context, Icons.person_outline, decorative: true),
            title: m.isMe ? '${m.name} (you)' : m.name,
            subtitle: s.notReady.contains(m.name)
                ? 'Needs to update the app first'
                : (m.verified ? 'Chose to keep data on their phone' : 'Uses the phone (has not chosen)'),
            info: !s.notReady.contains(m.name) && m.verified ? 'Nobody can change that for them.' : null,
            infoTitle: m.name,
            trailing: s.iAmAdmin && !m.isMe && !m.verified
                ? IconButton(
                    key: Key('remind-${m.userId}'),
                    tooltip: 'Copy a reminder for ${m.name}',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.notifications_active_outlined),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(
                          text: 'Hi ${m.name}, please open Orbitly > Settings > Server processing and choose how our circle "${widget.circle.name}" should handle your data.'));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reminder copied. Paste it in a message.')));
                      }
                    },
                  )
                : null,
          ),
      ]),
      Padding(
        padding: EdgeInsets.fromLTRB(inset, AppSpace.md, inset, AppSpace.xs),
        child: const Text('Message to send them:', style: AppType.secondary),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: const SelectableText(remindMessageText, key: Key('remind-message')),
      ),
      Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Align(
          alignment: Alignment.centerLeft,
          child: DsPillButton(
            key: const Key('remind-copy'),
            label: 'Copy message',
            style: DsPillStyle.outlined,
            icon: Icons.copy,
            onPressed: () => Clipboard.setData(const ClipboardData(text: remindMessageText)),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server processing')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _s == null
                ? DsErrorState(
                    key: const Key('proc-load-error'),
                    icon: _error!.icon,
                    title: _error!.title,
                    message: _error!.message,
                    onRetry: () => _load(force: true))
                : _body(_s!),
      ),
    );
  }

  /// A gap above a note or card that is not a [DsSectionHeader] (which brings its own).
  static const SizedBox _gap = SizedBox(height: AppSpace.md);

  Widget _body(ProcessingSnapshot s) {
    final ProcessingMember? me = s.me;
    final double inset = DsRowScope.insetFor(context);
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: DsSettingsList(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(inset, AppSpace.xs, inset, AppSpace.sm),
            child: Text(widget.circle.name, style: AppType.headline),
          ),
          if (!s.isPrivate)
            const ProcessingNote(
                noteKey: Key('proc-not-private'),
                icon: Icons.lock_open,
                text: 'This is a normal circle, not a Private circle. Your position is sent to the server in readable form. '
                    'Turn on "Private circle" in the circle settings (admins only) to use end-to-end encryption.')
          else ...<Widget>[
            _statusCard(s),
            if (s.problem != null) ...<Widget>[
              _gap,
              ProcessingNote(noteKey: const Key('proc-problem'), icon: Icons.sync_problem, color: AppColors.statusOrange, text: s.problem!),
            ],
            if (s.legacy) ...<Widget>[_gap, _legacyCard(s)],
            if (s.optOutPendingSince != null) ...<Widget>[
              _gap,
              const ProcessingNote(
                  noteKey: Key('proc-optout-pending'),
                  icon: Icons.sync_problem,
                  color: AppColors.statusOrange,
                  text: 'Not yet confirmed: the server still has your previous choice. Your phone already seals for phones only and keeps '
                      'trying to tell the server. Until it is confirmed, the server may still treat you as allowing it.'),
            ],
            if (s.undeliveredCount > 0) ...<Widget>[
              _gap,
              ProcessingNote(
                  noteKey: const Key('proc-undelivered'),
                  icon: Icons.report_problem_outlined,
                  color: AppColors.statusRed,
                  text: '${s.undeliveredCount} ${s.undeliveredCount == 1 ? 'item was' : 'items were'} not delivered to this circle'
                      '${s.undeliveredCode == 'required_server' ? ' because your family admin requires server processing and the server did not accept this phone\'s choice (not signed yet, out of date after a server key change, or an admin phone has to sign the circle policy again)' : ''}. '
                      '${s.undeliveredCode == 'required_server' ? 'This phone signs its choice by itself and sends what is waiting; if that does not happen, update the app or ask an admin.' : 'They are not kept. New positions are sent normally.'}'),
            ],
            if (s.required && s.members.any((ProcessingMember m) => m.isChild)) ...<Widget>[
              _gap,
              const ProcessingNote(
                  noteKey: Key('proc-child-note'),
                  icon: Icons.child_care,
                  text: 'This circle requires server processing and the rule applies to child accounts too. A child\'s phone switches '
                      'over by itself, like everyone else\'s.'),
            ],
            if (s.status == LaneStatus.verificationFailed) ...<Widget>[
              _gap,
              const ProcessingNote(
                  noteKey: Key('proc-verification-failed'),
                  icon: Icons.warning_amber,
                  color: AppColors.statusRed,
                  text: 'The key log or the processing records did not verify. Your phone treats this circle as phone only until they do.'),
            ],
            const DsSectionHeader('Circle setting'),
            DsRowGroup(children: <Widget>[
              DsListRow(
                key: const Key('proc-open-policy'),
                leading: DsListRow.iconTile(context, Icons.admin_panel_settings_outlined, decorative: true),
                title: _policyTitle(s),
                subtitle: s.iAmAdmin ? 'Change the circle setting' : 'View only',
                chevron: true,
                onTap: () async {
                  await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                      builder: (_) => ProcessingPolicyScreen(circle: widget.circle, controller: _c)));
                  if (mounted) _load(force: true);
                },
              ),
            ]),
            if (!s.iAmAdmin) const DsFootnote(ProcessingCopy.adminOnly, key: Key('proc-admin-only')),
            const DsSectionHeader('My data'),
            ..._myChoice(s, me),
            const DsSectionHeader('Members'),
            DsRowGroup(children: <Widget>[
              for (final ProcessingMember m in s.members) _memberRow(s, m),
            ]),
            if (s.iAmAdmin && s.assistOn && !s.legacy && s.members.any((ProcessingMember m) => !m.serverAssisted)) ..._notYetOnServer(s),
            if (s.viewers.isNotEmpty && !s.legacy) ...<Widget>[
              const DsSectionHeader('Viewers and bridges'),
              DsRowGroup(children: <Widget>[
                for (final ProcessingViewer v in s.viewers)
                  DsListRow(
                    key: Key('viewer-${v.ownerName}-${v.kind}'),
                    leading: DsListRow.iconTile(context, v.kind == 'web' ? Icons.web : Icons.hub_outlined, decorative: true),
                    title: v.kind == 'web' ? '${v.ownerName} has a web viewer' : '${v.ownerName} has a bridge',
                    subtitle: v.kind == 'web' ? 'May also read phone-only members' : 'Reads only members who allowed the server',
                    info: v.kind == 'web'
                        ? 'If ${v.ownerName} gave it this circle\'s key, it can read everyone ${v.ownerName} can read, including members who keep data on their phone.'
                        : 'A bridge (for example Dawarich) gets only the server key here: it reads members who allowed server processing, not phone-only members.',
                    infoTitle: v.kind == 'web' ? 'Web viewer' : 'Bridge',
                  ),
              ]),
            ],
            if (s.assistOn || s.serverCount > 0) ...<Widget>[
              const DsSectionHeader('Delete server copies', caption: 'Copies made while you allowed it stay until deleted.'),
              DsRowGroup(children: <Widget>[
                DsListRow(
                  key: const Key('delete-mine'),
                  leading: DsListRow.iconTile(context, Icons.delete_outline, decorative: true),
                  title: 'Delete my copies',
                  info: 'Copies the server made while you allowed it stay until deleted. Backups and anything already exported cannot be deleted.',
                  infoTitle: 'Delete my copies',
                  onTap: _busy ? null : () => _delete(whole: false),
                ),
                if (s.iAmAdmin)
                  DsListRow(
                    key: const Key('delete-all'),
                    leading: DsListRow.iconTile(context, Icons.delete_forever_outlined, color: AppColors.sosRed, decorative: true),
                    title: 'Delete all copies of this circle',
                    destructive: true,
                    onTap: _busy ? null : () => _delete(whole: true),
                  ),
              ]),
            ],
            const SizedBox(height: AppSpace.xl),
            DsRowGroup(children: <Widget>[
              DsListRow(
                key: const Key('proc-footnote'),
                leading: DsListRow.iconTile(context, Icons.info_outline, decorative: true),
                title: 'What the server can still see',
                info: '${ProcessingCopy.operatorCanRead} ${ProcessingCopy.metadata} ${ProcessingCopy.multiCircle}',
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _memberRow(ProcessingSnapshot s, ProcessingMember m) {
    final bool undecided = s.assistOn && !m.verified && !m.serverAssisted;
    final bool catchingUp = s.required && !m.serverAssisted;
    // The lane is a chip on the right; on a narrow screen or at large text a chip would be cut off, so it becomes the
    // first part of the second line instead.
    final bool asText = DsListRow.compactFor(context);
    final String? lane = s.unconfirmed || s.legacy
        ? null
        : (catchingUp ? ProcessingCopy.catchingUp : laneLabel(m.serverAssisted));
    final String? extra = s.unconfirmed
        ? 'Not confirmed right now'
        : s.legacy
            ? 'Old mode: the server may read it'
            : (!s.required && undecided ? 'Has not chosen' : null);
    final String subtitle = dsMeta(<String?>[asText ? lane : null, extra]);
    final String? info = s.unconfirmed
        ? null
        : s.legacy
            ? (m.isChild ? 'Child account. Old mode: the server may read it if everyone allowed it.' : 'Old mode: the server may read this circle if everyone allowed it.')
            : (catchingUp
                ? ProcessingCopy.catchingUpInfo
                : (undecided
                    ? '${m.name} has not chosen. Until they do, their data stays on their phone and is not sent to the server for processing.'
                    : null));
    return DsListRow(
      key: Key('member-${m.userId}'),
      leading: DsListRow.iconTile(context, Icons.person_outline, decorative: true),
      title: m.isMe ? '${m.name} (you)' : m.name,
      subtitle: subtitle.isEmpty ? null : subtitle,
      info: info,
      infoTitle: m.name,
      trailing: asText || lane == null ? null : (catchingUp ? const CatchingUpChip() : LaneChip(server: m.serverAssisted)),
    );
  }

  /// What the circle setting is, as the row's title (the state itself, not a label for a page).
  String _policyTitle(ProcessingSnapshot s) {
    if (s.legacy) return 'Old trusted-server mode';
    if (!s.assistOn) return 'Server assistance is off';
    return s.required ? 'Required by the admin' : 'Members may opt out';
  }

  Widget _statusCard(ProcessingSnapshot s) {
    final (IconData icon, Color color, String title, String sub, String? more) = s.unconfirmed
        ? (
            Icons.sync_problem,
            AppColors.statusOrange,
            'Not confirmed right now',
            'Your position is never sent unencrypted.',
            'Your position is never sent unencrypted. Where the admin requires server processing it waits until this phone has signed.'
          )
        : s.legacy
        ? (
            Icons.dns_outlined,
            AppColors.sosRed,
            ProcessingCopy.legacyStatusTitle,
            'The server holds the circle key and can read it.',
            ProcessingCopy.legacyStatusBody
          )
        : !s.assistOn
        ? (Icons.smartphone, AppColors.sky, 'Phones only', 'The server cannot read this circle.', null)
        : s.required
        ? (
            Icons.dns_outlined,
            AppColors.accentInk,
            'Required by the admin (${s.serverCount} of ${s.members.length} on the server)',
            s.serverCount == s.members.length ? 'Members cannot turn it off.' : 'Phones are switching over by themselves.',
            s.serverCount == s.members.length
                ? ProcessingCopy.requireSwitchBody
                : 'Everyone\'s phone switches over by itself. A phone that has not switched over cannot send positions until it has.'
          )
        : (
            Icons.dns_outlined,
            AppColors.accentInk,
            'Server-assisted (${s.serverCount} of ${s.members.length} members)',
            s.serverCount == s.members.length ? 'Everyone allowed server processing.' : 'Others keep their data on their phone.',
            null
          );
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool compact = DsListRow.compactFor(context);
    final Color fg = dark ? Color.lerp(color, Colors.white, 0.45)! : Color.lerp(color, Colors.black, 0.35)!;
    final double inset = DsRowScope.insetFor(context);
    return Semantics(
      container: true,
      label: 'Status: $title. $sub',
      child: Container(
        key: const Key('proc-status-card'),
        padding: EdgeInsets.fromLTRB(inset, AppSpace.md, more == null ? inset : AppSpace.xs, AppSpace.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.16 : 0.09),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(children: <Widget>[
          if (!compact) ...<Widget>[
            ExcludeSemantics(child: DsIconTile(icon, color: fg)),
            const SizedBox(width: AppSpace.md),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, key: const Key('proc-status-title'), style: AppType.body.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpace.xxs),
              Text(sub, style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurface)),
            ]),
          ),
          if (more != null) InfoHint(title: title, body: more),
        ]),
      ),
    );
  }

  Widget _legacyCard(ProcessingSnapshot s) {
    final double inset = DsRowScope.insetFor(context);
    return Container(
      key: const Key('proc-legacy-card'),
      padding: EdgeInsets.all(inset),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.statusOrange.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text('Old trusted-server mode', style: AppType.body),
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
    final bool mine = me?.serverAssisted ?? false;
    // Unknown state: no claim about the lane, no control (the note above says what is going on).
    if (s.unconfirmed) return const <Widget>[];
    // Required by the admin: no choice, no dead end. A calm notice; the phone signs by itself.
    if (s.required && !s.legacy) {
      return <Widget>[
        DsRowGroup(key: const Key('proc-required-notice'), children: <Widget>[
          DsListRow(
            leading: DsListRow.iconTile(context, Icons.dns_outlined, decorative: true),
            title: ProcessingCopy.requiredNoticeTitle,
            subtitle: 'Members cannot turn it off.',
            info: ProcessingCopy.requiredNoticeBody,
            infoTitle: 'Server processing is required',
          ),
          if (!mine)
            DsListRow(
              key: const Key('proc-required-catching-up'),
              leading: DsListRow.iconTile(context, Icons.sync, decorative: true),
              title: 'Your phone is switching over',
              subtitle: 'Positions are not delivered until then.',
              info: ProcessingCopy.requiredCatchingUp,
              infoTitle: 'Your phone is switching over',
            ),
        ]),
      ];
    }
    final bool undecided = s.assistOn && me != null && !me.verified;
    String? why;
    String? whyFull;
    if (!s.assistOn) {
      why = 'Server processing is off for this circle.';
      whyFull = 'Server processing is off for this circle, so your phone does the processing.';
    } else if (s.legacy) {
      why = 'Old trusted-server mode. Use the old settings above.';
      whyFull = 'This circle is in the old trusted-server mode. Use the old settings above until an admin upgrades it.';
    } else if (!s.hasServerKey && !mine) {
      why = 'No approved server key for this circle yet.';
      whyFull = 'This server has no approved server key for this circle yet, so server processing cannot be chosen.';
    }
    final bool canToggle = why == null && !_busy;
    final double inset = DsRowScope.insetFor(context);
    return <Widget>[
      if (undecided)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: Material(
            key: const Key('proc-choose'),
            color: BrandTheme.of(context).sheet,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Padding(
              padding: EdgeInsets.all(inset),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                const Text('Choose where your data is processed', style: AppType.body),
                const SizedBox(height: AppSpace.xs),
                Text(
                    'Your phone does the processing until you choose. The admin suggests '
                    '"${s.policy.defaultForNew == E2ee.lineServer ? 'Server processing' : 'Phone only'}"; that is only a suggestion. '
                    'Nothing is shared with the server unless you confirm it yourself.',
                    key: const Key('proc-default-hint'),
                    style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: AppSpace.md),
                Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: <Widget>[
                  DsPillButton(
                    key: const Key('choose-server'),
                    label: 'Server processing',
                    style: DsPillStyle.outlined,
                    onPressed: _busy || !s.hasServerKey ? null : () => _chooseUndecided(E2ee.lineServer),
                  ),
                  DsPillButton(
                    key: const Key('choose-phone'),
                    label: 'Phone only',
                    style: DsPillStyle.outlined,
                    onPressed: _busy ? null : () => _chooseUndecided(E2ee.linePhone),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      DsRowGroup(children: <Widget>[
        DsToggleRow(
          key: const Key('my-lane-switch'),
          icon: Icons.dns_outlined,
          title: 'Let the server process my data',
          subtitle: why ?? (mine ? 'On' : 'Off'),
          info: whyFull ??
              (mine
                  ? 'On. The server can read your location, trips and driving data. Switch off to keep them on your phone ("Don\'t send my data to the server").'
                  : 'Off. Your phone does the processing; end-to-end encryption between phones continues.'),
          value: mine,
          onChanged: canToggle && me != null
              ? (bool v) => v ? _optIn() : _optOut()
              : null,
        ),
      ]),
      if (!mine && s.assistOn) const DsFootnote(ProcessingCopy.phoneWorkNote, key: Key('proc-phone-note')),
    ];
  }
}
