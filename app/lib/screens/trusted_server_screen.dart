import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_widgets.dart';
import 'security_widgets.dart';

/// The wording shown wherever a member is asked to let the server read a circle.
/// Honest by design: the server host (and anyone who controls it, its backups
/// and its administrators) CAN read this circle's locations afterwards.
const String kTrustedServerWarning =
    'If you allow this, the Orbitly server can READ the location of every member of this circle, '
    'and it keeps a plaintext copy in its database (map, history, trips, place alerts, Dawarich export). '
    'Anyone who controls the server host, its backups or its database can read that copy. '
    'This is NOT end-to-end encryption against the server any more. It only protects against leaks of '
    'the database or backups of ciphertext, and against the network. Allow it only if you run and trust this server yourself. '
    'The server reads this circle only while EVERY member has allowed it. You can withdraw at any time, '
    'and you can delete the server\'s copies.';

/// Trusted-server mode for one circle: show the server's key, let this member
/// allow or withdraw, share the circle key with the server key once everyone
/// consented, and delete the server's plaintext copies.
class TrustedServerScreen extends StatefulWidget {
  const TrustedServerScreen({super.key, required this.circle, this.service});
  final Circle circle;
  final E2eeService? service;

  @override
  State<TrustedServerScreen> createState() => _TrustedServerScreenState();
}

class _TrustedServerScreenState extends State<TrustedServerScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  CircleE2eeState? _state;
  ServerMemberState _ss = ServerMemberState.off;
  DeviceKey? _key;
  Set<String> _ok = <String>{};
  String _me = '';
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
      _loading = true;
      _error = null;
    });
    try {
      final LocalIdentity? id = await _svc.identity();
      final CircleE2eeState st = await _svc.api.circleState(widget.circle.id);
      final ServerMemberState ss = await _svc.api.serverMemberState(widget.circle.id);
      final DeviceKey? key = E2eeService.serverKeyOf(st, ss);
      final Set<String> ok = key == null ? <String>{} : await _svc.verifiedConsentUsers(st, ss, key);
      if (!mounted) return;
      setState(() {
        _state = st;
        _ss = ss;
        _key = key;
        _ok = ok;
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
      final String m = e is StateError ? e.message : errorText(e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _allow() async {
    final DeviceKey k = _key!;
    final bool ok = await showDsConfirm(context,
        title: 'Let the Orbitly server read "${widget.circle.name}"?',
        message: '$kTrustedServerWarning\n\nServer key: ${k.short}\n${k.digits}',
        confirmLabel: 'I understand: allow the server',
        destructive: true);
    if (ok) await _run(() => _svc.consentToServer(widget.circle.id), 'You allowed the server to read this circle');
  }

  Future<void> _withdraw() async {
    final bool ok = await showDsConfirm(context,
        title: 'Withdraw your consent?',
        message: 'The server stops reading this circle at once, for everyone. A circle admin then publishes a new key '
            'so the server key gets nothing new. Copies the server already made stay until they are deleted.',
        confirmLabel: 'Withdraw',
        destructive: true);
    if (ok) await _run(() => _svc.withdrawServerConsent(widget.circle.id), 'Consent withdrawn');
  }

  Future<void> _purge({required bool whole}) async {
    final bool ok = await showDsConfirm(context,
        title: whole ? 'Delete all server copies of this circle?' : 'Delete the server\'s copies of your positions?',
        message: 'The server deletes the plaintext positions it decrypted from this circle'
            '${whole ? ' for all members' : ' for you'}. Sealed (encrypted) data and positions of your other circles are not touched.',
        confirmLabel: 'Delete copies',
        destructive: true);
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final int n = await _svc.purgeServerCopies(widget.circle.id, wholeCircle: whole);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted $n server copies')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Old trusted-server mode')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? LoadStateView(error: _error, offline: false, onRetry: _load)
                : _body(),
      ),
    );
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Widget _body() {
    final CircleE2eeState st = _state!;
    final bool admin = widget.circle.isAdmin;
    final List<String> need = E2eeService.membersNeedingConsent(st);
    final bool allOk = need.isNotEmpty && need.every(_ok.contains);
    final bool mine = _ok.contains(_me);
    final bool reads = _ss.serverMember && allOk;
    final DeviceKey? key = _key;
    final int allowed = need.where(_ok.contains).length;
    final bool ready = st.isPrivate && _ss.enabled && key != null;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          const Text('Orbitly server as a circle member', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Optional, off by default. It makes this circle readable by your own server again so the admin map, history, '
            'Dawarich sync and place alerts work.',
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.lg),
          _statusCard(st, key, need, allowed, reads),
          const SizedBox(height: AppSpace.lg),
          _meaning(),
          const SizedBox(height: AppSpace.lg),
          if (!st.isPrivate)
            const Text('This circle is not a Private circle.', key: Key('server-not-private'), style: AppType.secondary)
          else if (!_ss.enabled)
            _enrollSteps(
              const Key('server-disabled'),
              'This server is not set up to be a circle member (the default). If you own the server you can enable it:',
              showToken: true,
            )
          else if (key == null)
            _enrollSteps(
              const Key('server-no-key'),
              'No approved server key yet. If you own the server, enroll it and approve it from this phone:',
              showToken: false,
            )
          else ...<Widget>[
            const DsSectionHeader('Server key', padding: EdgeInsets.fromLTRB(0, 0, 0, AppSpace.xs)),
            Text(key.label.isEmpty ? 'Orbitly server' : key.label, key: const Key('server-name'), style: AppType.headline),
            const SizedBox(height: AppSpace.xxs),
            Text('Key: ${key.short}', key: const Key('server-short'), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpace.sm),
            DigitBlock(digits: key.digits, label: 'Server key digits', copyLabel: 'Copy fingerprint'),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Compare this key with the one printed on the server by the enroll command (or "status"). '
              'If it differs, do not allow it.',
              key: const Key('server-compare'),
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.xl),
            Text('$allowed of ${need.length} ${need.length == 1 ? 'member has' : 'members have'} allowed it',
                key: const Key('server-consent-count'), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpace.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                key: const Key('server-progress'),
                minHeight: 6,
                value: need.isEmpty ? 0 : allowed / need.length,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            DsRowGroup(children: <Widget>[
              for (final CircleE2eeMember m in st.members)
                if (need.contains(m.userId))
                  DsListRow(
                    key: Key('consent-${m.userId}'),
                    leading: DsListRow.iconTile(context, _ok.contains(m.userId) ? Icons.check_circle_outline : Icons.hourglass_top),
                    title: m.userId == _me ? '${m.name} (you)' : m.name,
                    subtitle: _ok.contains(m.userId) ? 'Allowed (signature checked on this phone)' : 'Has not allowed it',
                  ),
            ]),
            const SizedBox(height: AppSpace.lg),
            if (!mine)
              DsPillButton(key: const Key('server-allow'), label: 'Allow the server to read this circle', icon: Icons.lock_open, onPressed: _busy ? null : _allow)
            else
              const Text('You allowed it. The server reads this circle only once every member has.',
                  key: Key('server-you-allowed'), style: AppType.secondary),
            if (allOk && !_ss.wrapped) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              Text(
                'Everyone allowed it, but this phone no longer gives the server the circle key. Ask a circle admin to upgrade this '
                'circle (Server processing > Upgrade this circle): then each member decides for their own data.',
                key: const Key('server-use-upgrade'),
                style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
          if (ready) ...<Widget>[
            const DsSectionHeader('Withdraw or delete', padding: EdgeInsets.fromLTRB(0, AppSpace.xxl, 0, AppSpace.xs)),
            Text(
              'Withdrawing stops the server reading this circle at once. While it reads, the server stores plaintext '
              'positions; delete them here at any time, for example after withdrawing or revoking the server key. '
              'Each action asks you to confirm.',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.md),
            if (mine)
              DsPillButton(key: const Key('server-withdraw'), label: 'Withdraw my consent', style: DsPillStyle.outlined, icon: Icons.lock, onPressed: _busy ? null : _withdraw),
            if (mine) const SizedBox(height: AppSpace.sm),
            DsPillButton(
              key: const Key('server-purge-mine'),
              label: 'Delete my copies',
              style: DsPillStyle.outlined,
              icon: Icons.delete_outline,
              onPressed: _busy ? null : () => _purge(whole: false),
            ),
            if (admin) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              DsPillButton(
                key: const Key('server-purge-all'),
                label: 'Delete all copies of this circle',
                style: DsPillStyle.danger,
                icon: Icons.delete_forever_outlined,
                onPressed: _busy ? null : () => _purge(whole: true),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _statusCard(CircleE2eeState st, DeviceKey? key, List<String> need, int allowed, bool reads) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String title, String sub) = !st.isPrivate || !_ss.enabled
        ? (Icons.power_settings_new, AppColors.statusGrey, 'Off', 'The server cannot read this circle')
        : key == null
            ? (Icons.hourglass_top, AppColors.statusOrange, 'Waiting for enrolment', 'The server has no approved key yet')
            : reads
                ? (Icons.visibility, AppColors.sosRed, 'Active', 'Server can read this circle')
                : (
                    Icons.how_to_vote_outlined,
                    AppColors.statusOrange,
                    need.length - allowed == 1 ? 'Waiting for 1 member' : 'Waiting for ${need.length - allowed} members',
                    'The server cannot read this circle yet'
                  );
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = dark ? Color.lerp(color, Colors.white, 0.45)! : Color.lerp(color, Colors.black, 0.35)!;
    return Semantics(
      container: true,
      label: 'Status: $title. $sub',
      child: Container(
        key: const Key('server-status-card'),
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
              Text(title, style: AppType.headline.copyWith(color: fg)),
              Text(sub, key: const Key('server-state'), style: AppType.secondary.copyWith(color: cs.onSurface)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _meaning() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget bullet(IconData i, Widget t) => Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Icon(i, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: AppSpace.sm),
            Expanded(child: t),
          ]),
        );
    return Material(
      key: const Key('server-warning'),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('WHAT THIS MEANS', style: AppType.label.copyWith(color: cs.onSurfaceVariant)),
        bullet(
          Icons.visibility,
          Text('The server can read every member\'s location.', style: AppType.body.copyWith(fontWeight: FontWeight.w800, color: AppColors.sosRed)),
        ),
        bullet(Icons.storage, Text('It keeps a plaintext copy in its database.', style: AppType.body.copyWith(fontWeight: FontWeight.w400))),
        bullet(Icons.lock_open, Text('This is no longer end-to-end encryption against the server.', style: AppType.body.copyWith(fontWeight: FontWeight.w400))),
        bullet(Icons.groups_outlined, Text('It reads a circle only while every member has allowed it.', style: AppType.body.copyWith(fontWeight: FontWeight.w400))),
        bullet(Icons.undo, Text('You can withdraw and delete the copies at any time.', style: AppType.body.copyWith(fontWeight: FontWeight.w400))),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: const ExpansionTile(
            key: Key('server-details'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.only(bottom: AppSpace.md),
            title: Text('Read details', style: TextStyle(fontWeight: FontWeight.w700)),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[Text(kTrustedServerWarning, style: AppType.secondary)],
          ),
        ),
      ]),
    ));
  }

  Widget _enrollSteps(Key key, String intro, {required bool showToken}) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    const String tokenCmd = 'export E2EE_SERVER_INGEST_TOKEN=\$(openssl rand -hex 32)   # put it in .env';
    const String enrollCmd = 'docker compose --profile e2ee-server run --rm -T e2ee-server-device enroll --kind server '
        '--server http://api:8080 --email you@example.org < password.txt';
    Widget cmd(String c, String what) => Container(
          margin: const EdgeInsets.only(top: AppSpace.xs),
          padding: const EdgeInsets.only(left: AppSpace.md),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(children: <Widget>[
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: AppSpace.sm), child: SelectableText(c, style: kMono.copyWith(fontSize: 12, color: cs.onSurface)))),
            IconButton(tooltip: 'Copy $what', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(c, what)),
          ]),
        );
    Widget step(int n, String t, {Widget? extra}) => Padding(
          padding: const EdgeInsets.only(top: AppSpace.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            CircleAvatar(radius: 12, backgroundColor: cs.primaryContainer, child: Text('$n', style: AppType.label.copyWith(color: cs.onPrimaryContainer))),
            const SizedBox(width: AppSpace.md),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Text(t, style: AppType.body.copyWith(fontWeight: FontWeight.w400)), if (extra != null) extra])),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(intro, key: key, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
        if (showToken) step(1, 'Set E2EE_SERVER_INGEST_TOKEN on the server (at least 32 characters).', extra: cmd(tokenCmd, 'token command')),
        step(showToken ? 2 : 1, 'Run the enroll command. It prints the server key name, fingerprint and a request code.', extra: cmd(enrollCmd, 'enroll command')),
        step(showToken ? 3 : 2, 'Approve the request code on this phone under "Approve a viewer or bridge", then run enroll with --approval.'),
        step(showToken ? 4 : 3, 'Come back here and compare the fingerprint with the one the command printed.'),
      ]),
    );
  }
}
