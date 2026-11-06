import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_widgets.dart';
import 'security_widgets.dart';

/// Human wording for a device-member kind.
String viewerKindLabel(String? kind) => switch (kind) {
      'web' => 'Web viewer (browser)',
      'service' => 'Dawarich bridge (server process)',
      'server' => 'OpenFamily server (can read the circle)',
      _ => 'Phone',
    };

bool _isViewerKind(String k) => k == 'web' || k == 'service' || k == 'server';

/// Approves a read-only "device member" of the Private circles of this account:
/// a browser viewer or a Dawarich bridge. The viewer shows a request code; this
/// phone signs its key (same cross-signing as a second phone) and shows an
/// approval code to paste back. Codes are never stored or logged.
class ViewerApprovalScreen extends StatefulWidget {
  const ViewerApprovalScreen({super.key, required this.circle, this.service});
  final Circle circle;
  final E2eeService? service;

  @override
  State<ViewerApprovalScreen> createState() => _ViewerApprovalScreenState();
}

class _ViewerApprovalScreenState extends State<ViewerApprovalScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  final TextEditingController _codeIn = TextEditingController();
  LinkRequestInfo? _info;
  String? _approval;
  String? _message;
  String? _error;
  bool _busy = false;
  bool _loading = true;
  String _me = '';
  CircleE2eeState? _state;
  List<DeviceKey> _waiting = <DeviceKey>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _codeIn.dispose();
    super.dispose();
  }

  String _msg(Object e) {
    if (e is E2eeFormatException) return e.message;
    if (e is E2eeAuthException) return 'The code is corrupted or forged.';
    if (e is FormatException) return 'This is not a valid request code. Paste the whole code.';
    if (e is StateError) return e.message;
    return errorText(e);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final LocalIdentity? id = await _svc.identity();
      final CircleE2eeState st = await _svc.api.circleState(widget.circle.id);
      List<DeviceKey> waiting = <DeviceKey>[];
      if (st.isPrivate && id != null) {
        try {
          await _svc.syncCircleKeys(widget.circle.id);
          // Wraps what is safe (own cross-signed keys) automatically.
          await _svc.processPending(widget.circle.id);
        } catch (_) {
          // Shown below as keys still waiting.
        }
        waiting = (await _svc.api.pending(widget.circle.id))
            .where((DeviceKey k) => k.userId == id.userId && _isViewerKind(k.kind) && k.isActive)
            .toList();
      }
      if (!mounted) return;
      setState(() {
        _state = st;
        _waiting = waiting;
        _me = id?.userId ?? '';
        _loading = false;
      });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _msg(e);
      });
    }
  }

  Future<void> _guard(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _message = _msg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _inspect() => _guard(() async {
        final LinkRequestInfo i = await _svc.inspectViewerRequest(_codeIn.text);
        setState(() {
          _info = i;
          _approval = null;
        });
      });

  void _cancel() {
    setState(() {
      _info = null;
      _approval = null;
      _message = null;
      _codeIn.clear();
    });
  }

  Future<void> _approve() => _guard(() async {
        final String a = await _svc.approveLinkRequest(_info!);
        setState(() => _approval = a);
      });

  Future<void> _share(DeviceKey k) => _guard(() async {
        await _svc.confirmWrap(widget.circle.id, k);
        _snack('Key shared');
        await _load();
      });

  Future<void> _deny(DeviceKey k) async {
    final bool ok = await showDsConfirm(context,
        title: 'Deny this ${viewerKindLabel(k.kind)}?',
        message: 'Its key is revoked on your account and it never receives the circle key.',
        confirmLabel: 'Deny',
        destructive: true);
    if (!ok) return;
    await _guard(() async {
      await _svc.revokeKey(k);
      _snack('Key denied');
      await _load();
    });
  }

  Future<void> _revoke(DeviceKey k) async {
    final bool admin = widget.circle.isAdmin;
    final bool ok = await showDsConfirm(context,
        title: 'Revoke "${_nameOf(k)}"?',
        message: 'This ${viewerKindLabel(k.kind)} stops receiving new data after a new key epoch. '
            'Data it already received stays readable by it. The key is revoked for all your Private circles. '
            '${admin ? 'As a circle admin you publish the new key now, so it cannot read what comes next.' : 'Only a circle admin can publish the new key; the server flags the circle (a new key is required) and an admin has to rotate it.'}',
        confirmLabel: 'Revoke',
        destructive: true);
    if (!ok) return;
    await _guard(() async {
      await _svc.revokeKey(k);
      if (admin) await _svc.bumpEpoch(widget.circle.id);
      _snack(admin ? 'Revoked, new key published' : 'Revoked. A circle admin must publish a new key');
      await _load();
    });
  }

  String _nameOf(DeviceKey k) => k.label.isNotEmpty ? k.label : viewerKindLabel(k.kind);

  String _when(DateTime t) {
    final DateTime l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Approve a viewer or bridge')),
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
    final List<DeviceKey> mineViewers = <DeviceKey>[];
    final List<(String, DeviceKey)> others = <(String, DeviceKey)>[];
    for (final CircleE2eeMember m in st.members) {
      for (final DeviceKey d in m.devices) {
        if (!_isViewerKind(d.kind) || !d.isActive) continue;
        if (m.userId == _me) {
          mineViewers.add(d);
        } else {
          others.add((m.name, d));
        }
      }
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          const Text('Approve a viewer or bridge', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          const Text(
            'A web viewer or a Dawarich bridge shows its request code. Paste it here, compare the digits with the ones it shows, then approve.',
            style: AppType.secondary,
          ),
          if (!st.isPrivate)
            const Padding(
              padding: EdgeInsets.only(top: AppSpace.md),
              child: Text('This circle is not a Private circle, so there is no key to share.', style: AppType.secondary),
            ),
          const SizedBox(height: AppSpace.md),
          TextField(
            key: const Key('viewer-code'),
            controller: _codeIn,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Request code from the viewer or bridge'),
          ),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(label: 'Inspect', style: DsPillStyle.tonal, icon: Icons.search, onPressed: _busy ? null : _inspect),
          if (_message != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Semantics(liveRegion: true, child: Text(_message!, key: const Key('viewer-message'), style: AppType.body.copyWith(color: AppColors.sosRed))),
          ],
          if (_info != null) ..._inspected(_info!),
          if (st.isPrivate) ..._lists(mineViewers, others),
        ],
      ),
    );
  }

  List<Widget> _inspected(LinkRequestInfo i) {
    return <Widget>[
      const SizedBox(height: AppSpace.lg),
      Text(i.name == null || i.name!.isEmpty ? 'Unnamed device' : i.name!, key: const Key('viewer-name'), style: AppType.headline),
      Text(viewerKindLabel(i.kind), key: const Key('viewer-kind'), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: AppSpace.sm),
      Text('Key: ${i.short}', key: const Key('viewer-short'), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: AppSpace.xs),
      DigitBlock(digits: i.digits, label: 'Key digits'),
      const SizedBox(height: AppSpace.sm),
      const Text(
        'Compare these digits with the digits the viewer or bridge shows. Only approve if every group matches.',
        key: Key('viewer-compare'),
      ),
      const SizedBox(height: AppSpace.sm),
      Container(
        key: const Key('viewer-warning'),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.sosRed),
          borderRadius: BorderRadius.circular(12),
        ),
        child: i.isServer
            ? const Text(
                'This is the key of the OpenFamily SERVER itself. Approving it only registers the key for your account. '
                'It can read nothing until you open a Private circle\'s "Trusted server" screen, every member of that circle '
                'allows it, and a circle admin gives it the circle key. After that the server CAN READ that circle and keeps a '
                'plaintext copy; anyone who controls the server host can read it too. Approve only the server you run yourself.',
                key: Key('viewer-server-warning'),
              )
            : Text(
                'If you approve, this ${i.kind == 'service' ? 'bridge' : 'viewer'} can READ the location of every member of all your Private circles '
                '(every circle your account is in that is private), now and in the future, until you revoke it. '
                '${i.kind == 'service' ? 'Whoever runs the server where the bridge runs can read that data. ' : 'Whoever controls the browser and the device it runs on can read that data. '}'
                'Approve only a viewer or bridge you set up yourself. The kind is not part of the signed approval, so check it here.',
              ),
      ),
      const SizedBox(height: AppSpace.sm),
      Row(children: <Widget>[
        Expanded(
          child: DsPillButton(
            label: 'It matches: approve',
            icon: Icons.verified_user,
            onPressed: _busy || _approval != null ? null : _approve,
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        TextButton(onPressed: _busy ? null : _cancel, child: const Text('Cancel')),
      ]),
      if (_approval != null) ...<Widget>[
        const SizedBox(height: AppSpace.md),
        const Text('Approval code. Copy it into the viewer or bridge. It is shown only now and is not stored:'),
        SelectableText(_approval!, key: const Key('viewer-approval'), style: AppType.secondary.copyWith(fontFamily: 'monospace')),
        TextButton.icon(onPressed: () => _copy(_approval!), icon: const Icon(Icons.copy), label: const Text('Copy approval')),
        const Text(
          'After you paste it, the viewer registers itself. Come back to this screen and it appears under "Waiting for a key" '
          'if it still needs the circle key (this screen shares it automatically when it can).',
          style: AppType.secondary,
        ),
      ],
    ];
  }

  List<Widget> _lists(List<DeviceKey> mine, List<(String, DeviceKey)> others) {
    return <Widget>[
      const DsSectionHeader('Waiting for a key', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
      if (_waiting.isEmpty)
        const Text('No viewer or bridge is waiting for the circle key.', key: Key('waiting-empty'), style: AppType.secondary)
      else
        for (final DeviceKey k in _waiting)
          Card(
            key: Key('waiting-${k.deviceId}'),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(_nameOf(k), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
                Text('${viewerKindLabel(k.kind)}, key ${k.short}', style: AppType.secondary),
                Text(k.fingerprint, style: AppType.secondary.copyWith(fontFamily: 'monospace')),
                if (k.approved == false) const Text('Waiting for approval by a circle admin first.', style: AppType.secondary),
                const SizedBox(height: AppSpace.xs),
                Wrap(spacing: AppSpace.sm, children: <Widget>[
                  FilledButton(
                    key: Key('share-${k.deviceId}'),
                    onPressed: _busy || k.approved == false || k.kind == 'server' ? null : () => _share(k),
                    child: Text(k.kind == 'server' ? 'Use "Trusted server"' : 'Share key'),
                  ),
                  OutlinedButton(key: Key('deny-${k.deviceId}'), onPressed: _busy ? null : () => _deny(k), child: const Text('Deny')),
                ]),
              ]),
            ),
          ),
      const DsSectionHeader('Connected viewers', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
      if (mine.isEmpty)
        const Text('No viewer or bridge is connected to your account.', key: Key('connected-empty'), style: AppType.secondary)
      else
        for (final DeviceKey k in mine)
          Card(
            key: Key('connected-${k.deviceId}'),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(_nameOf(k), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
                Text('${viewerKindLabel(k.kind)}, key ${k.short}', style: AppType.secondary),
                Text('Added ${_when(k.createdAt)}', style: AppType.secondary),
                const SizedBox(height: AppSpace.xs),
                OutlinedButton(key: Key('revoke-${k.deviceId}'), onPressed: _busy ? null : () => _revoke(k), child: const Text('Revoke')),
              ]),
            ),
          ),
      if (others.isNotEmpty) ...<Widget>[
        const DsSectionHeader("Other members' viewers", padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
        DsRowGroup(children: <Widget>[
          for (final (String owner, DeviceKey k) in others)
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.devices_other),
              title: '${_nameOf(k)} ($owner)',
              subtitle: '${viewerKindLabel(k.kind)}, key ${k.short}, added ${_when(k.createdAt)}',
            ),
        ]),
      ],
    ];
  }
}
