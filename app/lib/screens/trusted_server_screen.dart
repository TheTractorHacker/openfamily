import 'package:flutter/material.dart';

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
    'If you allow this, the OpenFamily server can READ the location of every member of this circle, '
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
        title: 'Let the OpenFamily server read "${widget.circle.name}"?',
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
      appBar: AppBar(title: const Text('Trusted server')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? LoadStateView(error: _error, offline: false, onRetry: _load)
                : _body(),
      ),
    );
  }

  Widget _body() {
    final CircleE2eeState st = _state!;
    final bool admin = widget.circle.isAdmin;
    final List<String> need = E2eeService.membersNeedingConsent(st);
    final bool allOk = need.isNotEmpty && need.every(_ok.contains);
    final bool mine = _ok.contains(_me);
    final bool reads = _ss.serverMember && allOk;
    final DeviceKey? key = _key;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          const Text('OpenFamily server as a circle member', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          const Text(
            'Optional, off by default. It makes this circle readable by your own server again so the admin map, history, '
            'Dawarich sync and place alerts work. Every member must allow it.',
            style: AppType.secondary,
          ),
          const SizedBox(height: AppSpace.md),
          Container(
            key: const Key('server-warning'),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(border: Border.all(color: AppColors.sosRed), borderRadius: BorderRadius.circular(12)),
            child: const Text(kTrustedServerWarning),
          ),
          const SizedBox(height: AppSpace.md),
          if (!st.isPrivate)
            const Text('This circle is not a Private circle.', key: Key('server-not-private'), style: AppType.secondary)
          else if (!_ss.enabled)
            const Text(
              'This server is not set up to be a circle member (the default). The server owner can enable it; see the docs "Trusted-server mode".',
              key: Key('server-disabled'),
              style: AppType.secondary,
            )
          else if (key == null)
            const Text(
              'No approved server key yet. On the server, run the enroll command, then approve its request code under '
              '"Approve a viewer or bridge". It will appear here with its fingerprint.',
              key: Key('server-no-key'),
              style: AppType.secondary,
            )
          else ...<Widget>[
            Text(key.label.isEmpty ? 'OpenFamily server' : key.label, key: const Key('server-name'), style: AppType.headline),
            Text('Key: ${key.short}', key: const Key('server-short'), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
            DigitBlock(digits: key.digits, label: 'Server key digits'),
            const Text(
              'Compare this key with the one printed on the server by the enroll command (or "status"). '
              'If it differs, do not allow it.',
              key: Key('server-compare'),
              style: AppType.secondary,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              reads ? 'Server can read this circle' : 'The server cannot read this circle yet',
              key: const Key('server-state'),
              style: AppType.body.copyWith(fontWeight: FontWeight.w800, color: reads ? AppColors.sosRed : null),
            ),
            const DsSectionHeader('Members who allowed it', padding: EdgeInsets.fromLTRB(0, AppSpace.lg, 0, AppSpace.xs)),
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
            const SizedBox(height: AppSpace.md),
            if (!mine)
              DsPillButton(key: const Key('server-allow'), label: 'Allow the server to read this circle', icon: Icons.lock_open, onPressed: _busy ? null : _allow)
            else
              DsPillButton(key: const Key('server-withdraw'), label: 'Withdraw my consent', style: DsPillStyle.tonal, icon: Icons.lock, onPressed: _busy ? null : _withdraw),
            if (allOk && !_ss.wrapped) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              DsPillButton(
                key: const Key('server-share'),
                label: 'Give the server the circle key',
                icon: Icons.vpn_key,
                onPressed: _busy ? null : () => _run(() => _svc.shareKeyWithServer(widget.circle.id), 'Key shared with the server'),
              ),
              const Text('Everyone allowed it. The server can read the circle once the key reaches it.', style: AppType.secondary),
            ],
          ],
          if (st.isPrivate && _ss.enabled) ...<Widget>[
            const DsSectionHeader('Copies on the server', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            const Text(
              'While the server reads this circle it stores plaintext positions. Delete them here at any time, for example after withdrawing consent or revoking the server key.',
              style: AppType.secondary,
            ),
            const SizedBox(height: AppSpace.sm),
            OutlinedButton(key: const Key('server-purge-mine'), onPressed: _busy ? null : () => _purge(whole: false), child: const Text('Delete my copies')),
            if (admin)
              OutlinedButton(key: const Key('server-purge-all'), onPressed: _busy ? null : () => _purge(whole: true), child: const Text('Delete all copies of this circle')),
          ],
        ],
      ),
    );
  }
}
