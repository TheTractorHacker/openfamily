import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_trust.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_widgets.dart';
import 'member_safety_screen.dart';
import 'security_widgets.dart';

/// One circle's encryption: status, new-key duty, requests from new/replacement
/// keys ("Waiting for approval"), and every member's verification state.
class EncryptionCircleScreen extends StatefulWidget {
  const EncryptionCircleScreen({super.key, required this.circle, this.service});
  final Circle circle;
  final E2eeService? service;

  @override
  State<EncryptionCircleScreen> createState() => _EncryptionCircleScreenState();
}

class _EncryptionCircleScreenState extends State<EncryptionCircleScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  CircleE2eeState? _state;
  PendingReport _pending = const PendingReport();
  Map<String, TrustAssessment> _trust = <String, TrustAssessment>{};
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
      PendingReport p = const PendingReport();
      if (st.isPrivate && id != null) {
        await _svc.syncCircleKeys(widget.circle.id);
        p = await _svc.processPending(widget.circle.id);
      }
      final Map<String, TrustAssessment> t = <String, TrustAssessment>{};
      for (final CircleE2eeMember m in st.members) {
        t[m.userId] = await _svc.trust.assess(m.userId, m.devices.map((DeviceKey d) => d.fingerprint));
      }
      if (!mounted) return;
      setState(() {
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
                ? LoadStateView(error: _error, offline: false, onRetry: _load)
                : _body(_state!),
      ),
    );
  }

  Widget _body(CircleE2eeState st) {
    final bool admin = widget.circle.isAdmin;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          Text(st.isPrivate ? 'Private circle, key epoch ${st.epoch}' : 'Normal circle (not end-to-end encrypted)', style: AppType.headline),
          const SizedBox(height: AppSpace.sm),
          Text(
            st.isPrivate
                ? 'The circle key is held only by members\' phones. In this version locations are still sent the normal way; the key setup is ready for the next step.'
                : 'Turn on "Private circle" in the circle\'s settings (admins only) to set up end-to-end keys.',
            style: AppType.secondary,
          ),
          if (st.isPrivate && st.rekeyRequired) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            AlarmBanner(
              alarm: E2eeAlarm(AlarmKind.keyChanged, 'A new circle key is needed',
                  'A member left or a device key was revoked. ${admin ? 'Publish a new key so the people who left cannot read what comes next.' : 'A circle admin has to publish a new key.'}'),
            ),
            if (admin)
              DsPillButton(
                label: 'Publish new key',
                icon: Icons.vpn_key,
                onPressed: _busy ? null : () => _run(() async => _svc.bumpEpoch(widget.circle.id), 'New key published'),
              ),
          ],
          if (_pending.needConfirm.isNotEmpty || _pending.waiting.isNotEmpty) ...<Widget>[
            const DsSectionHeader('Key requests', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            DsRowGroup(children: <Widget>[
              for (final PendingItem p in _pending.needConfirm)
                DsListRow(
                  leading: DsListRow.iconTile(context, Icons.key, color: const Color(0xFFD97706)),
                  title: p.key.userName ?? 'A member',
                  subtitle: '${p.result.reason}. Compare the safety number before sharing the circle key.',
                  chevron: true,
                  onTap: _busy
                      ? null
                      : () async {
                          if (await _confirmRequest(p, action: 'It matches: share key')) {
                            await _run(() => _svc.confirmWrap(widget.circle.id, p.key, markVerified: true), 'Key shared');
                          }
                        },
                ),
              for (final PendingItem p in _pending.waiting)
                DsListRow(
                  leading: DsListRow.iconTile(context, Icons.hourglass_top),
                  title: '${p.key.userName ?? 'A member'}: Waiting for approval',
                  subtitle: admin
                      ? 'This replacement key is not cross-signed by an earlier key. Compare the safety number, then approve it for this circle.'
                      : 'A circle admin must approve this replacement key.',
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
          const DsSectionHeader('Members', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          DsRowGroup(children: <Widget>[
            for (final CircleE2eeMember m in st.members)
              DsListRow(
                leading: DsListRow.iconTile(context, Icons.person_outline),
                title: m.userId == _me ? '${m.name} (you)' : m.name,
                subtitle: m.devices.isEmpty
                    ? 'No encryption key registered yet'
                    : '${m.devices.length} key${m.devices.length == 1 ? '' : 's'}${m.devices.any((DeviceKey d) => d.approved == false) ? ' - waiting for approval' : ''}',
                trailing: m.userId == _me ? null : VerifiedBadge(level: _trust[m.userId]?.level ?? TrustLevel.unseen),
                chevron: m.userId != _me && m.devices.isNotEmpty,
                onTap: (m.userId == _me || m.devices.isEmpty)
                    ? null
                    : () async {
                        await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                            builder: (_) => MemberSafetyScreen(userId: m.userId, name: m.name, service: _svc)));
                        if (mounted) _load();
                      },
              ),
          ]),
        ],
      ),
    );
  }
}
