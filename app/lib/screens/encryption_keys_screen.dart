import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_trust.dart';
import '../services/e2ee/e2ee_vault.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_circle_screen.dart';
import 'encryption_widgets.dart';
import 'key_log_screen.dart';
import 'security_widgets.dart';
import 'link_device_screen.dart';
import 'recovery_screens.dart';

/// Settings > Security > Encryption keys. Plain status and the two everyday actions up top; the technical items sit under Advanced.
///
/// Shows this phone's key fingerprint (large, copyable, QR), when it was made,
/// where its storage key lives, a "Check server record" action, per-circle
/// encryption status and the way into each member's safety number.
class EncryptionKeysScreen extends StatefulWidget {
  const EncryptionKeysScreen({super.key, this.service, this.circles});
  final E2eeService? service;
  final CircleService? circles;

  @override
  State<EncryptionKeysScreen> createState() => _EncryptionKeysScreenState();
}

class _CircleRow {
  _CircleRow(this.circle, this.state);
  final Circle circle;
  final CircleE2eeState? state;
}

class _EncryptionKeysScreenState extends State<EncryptionKeysScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  CircleService get _circles => widget.circles ?? CircleService.instance;

  LocalIdentity? _id;
  String _digits = '';
  DeviceKey? _myRecord;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  ServerRecordCheck? _check;
  List<_CircleRow> _rows = <_CircleRow>[];
  List<E2eeAlarm> _alarms = <E2eeAlarm>[];
  KeystoreStatus? _store;

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
      final List<DeviceKey> mine = id == null ? <DeviceKey>[] : await _svc.api.myKeys();
      DeviceKey? rec;
      for (final DeviceKey k in mine) {
        if (id != null && k.deviceId == id.deviceId && k.isActive) rec = k;
      }
      final List<_CircleRow> rows = <_CircleRow>[];
      final Map<String, String> circleNames = <String, String>{};
      final Map<String, String> userNames = <String, String>{};
      if (rec != null) {
        for (final Circle c in await _circles.listCircles()) {
          circleNames[c.id] = c.name;
          CircleE2eeState? st;
          try {
            st = await _svc.api.circleState(c.id);
            for (final CircleE2eeMember m in st.members) {
              userNames[m.userId] = m.name;
            }
            await _svc.rememberPeers(st);
            if (st.isPrivate) {
              await _svc.syncCircleKeys(c.id);
              await _svc.processPending(c.id);
            }
            await _checkPendingInviter(c.id);
          } catch (_) {
            // A circle that fails to load is shown without status.
          }
          rows.add(_CircleRow(c, st));
        }
      }
      List<E2eeAlarm> alarms = <E2eeAlarm>[];
      if (rec != null) {
        final LogSync ls = await _svc.syncLog(userNames: userNames, circleNames: circleNames);
        alarms = ls.alarms;
        for (final _CircleRow r in rows) {
          final CircleE2eeState? st = r.state;
          if (st == null) continue;
          for (final CircleE2eeMember m in st.members) {
            if (m.userId == id?.userId) continue;
            final TrustAssessment a = await _svc.trust.assess(m.userId, m.devices.map((DeviceKey d) => d.fingerprint));
            if (a.alarming) {
              alarms = <E2eeAlarm>[
                ...alarms,
                E2eeAlarm(AlarmKind.verifiedKeyChanged, '${m.name}\'s encryption key changed',
                    'You verified ${m.name} before, and their keys are now different. '
                    'This can happen when they get a new phone, but it is also what an '
                    'attacker would cause. Do not trust new messages from ${m.name} until you '
                    'compare the safety number in person.',
                    userId: m.userId),
              ];
            }
          }
        }
      }
      final String? pendingInviter = rec == null ? null : await _svc.trust.pendingInviter();
      if (pendingInviter != null && rows.isNotEmpty) {
        alarms = <E2eeAlarm>[
          ...alarms,
          const E2eeAlarm(
              AlarmKind.inviterMismatch,
              'The person who invited you could not be matched',
              'The invite link carried the inviter\'s key fingerprint, but none of the keys the server shows in your circles matches it. '
              'Either you joined a circle by another route, or the server is showing you a different key than the one the inviter has. '
              'Compare safety numbers with the inviter in person before trusting this circle.'),
        ];
      }
      final KeystoreStatus store = await _svc.vault.status();
      if (!mounted) return;
      setState(() {
        _id = id;
        _myRecord = rec;
        _rows = rows;
        _alarms = alarms;
        _store = store;
        _loading = false;
      });
      if (id != null) {
        final String d = await id.digits;
        if (mounted) setState(() => _digits = d);
      }
    } on SessionExpiredException {
      return;
    } on VaultInvalidatedException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'This phone\'s key storage was reset (for example the screen lock was removed). '
            'The private keys cannot be read any more. Restore with your recovery phrase.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorText(e);
      });
    }
  }

  Future<void> _checkPendingInviter(String circleId) async {
    final String? fp = await _svc.trust.pendingInviter();
    if (fp == null) return;
    final String? who = await _svc.checkInviter(circleId, fp);
    if (who != null) await _svc.trust.clearPendingInviter();
  }

  Future<void> _setup() async {
    setState(() => _busy = true);
    try {
      await _svc.registerThisDevice(label: 'This phone');
      await _load();
    } on NeedsCrossSignatureException {
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => LinkDeviceScreen(service: _svc)));
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkServer() async {
    setState(() => _busy = true);
    try {
      final ServerRecordCheck c = await _svc.checkServerRecord();
      if (mounted) setState(() => _check = c);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption keys')),
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
    final LocalIdentity? id = _id;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.xl),
        children: <Widget>[
          for (final E2eeAlarm a in _alarms) AlarmBanner(alarm: a),
          if (id == null || _myRecord == null) _setupCard(id) else _statusCard(),
          const SizedBox(height: AppSpace.lg),
          if (id != null && _myRecord != null)
            DsRowGroup(children: <Widget>[
              DsListRow(
                key: const Key('keys-recovery'),
                leading: DsListRow.iconTile(context, Icons.pin_outlined),
                title: 'Recovery phrase',
                subtitle: '24 words to get your circles back',
                info: 'Write down 24 words to get your encrypted circles back on a new phone. '
                    'If you lose every phone and the recovery phrase, the encrypted data of your private circles '
                    'cannot be recovered by anyone, including the server operator.',
                chevron: true,
                onTap: () => _push(RecoverySetupScreen(service: _svc)),
              ),
              DsListRow(
                key: const Key('keys-link'),
                leading: DsListRow.iconTile(context, Icons.phonelink_setup),
                title: 'Link another phone',
                subtitle: 'Add a new phone to your account',
                info: 'Use this on a new phone, or to approve a new phone from this one. '
                    'You will need both phones in front of you.',
                chevron: true,
                onTap: () => _push(LinkDeviceScreen(service: _svc)),
              ),
            ]),
          if (_rows.isNotEmpty) ...<Widget>[
            const DsSectionHeader('Circles', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
            DsRowGroup(children: <Widget>[for (final _CircleRow r in _rows) _circleRow(r)]),
          ],
          if (id != null && _myRecord != null) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            DsRowGroup(children: <Widget>[
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const Key('keys-advanced'),
                  leading: DsListRow.iconTile(context, Icons.settings_outlined),
                  title: const Text('Advanced', style: AppType.body),
                  subtitle: const Text('Fingerprint, key storage, checks', style: AppType.secondary),
                  childrenPadding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.lg),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[..._deviceSection(id), ..._advancedRows()],
                ),
              ),
            ]),
          ],
          const SizedBox(height: AppSpace.xxl),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final bool lockedOk = _store?.usableWhileLocked ?? true;
    return DsRowGroup(children: <Widget>[
      DsListRow(
        key: const Key('keys-status'),
        leading: DsListRow.iconTile(context, Icons.verified_user_outlined),
        title: 'Your keys are safe on this phone',
        subtitle: lockedOk ? 'Works with the screen locked' : 'Unlock the phone once to finish updating',
        info: 'Private circles are end-to-end encrypted: the keys are made on this phone and never leave it. '
            'The server only stores public keys and scrambled copies it cannot read.',
        infoTitle: 'Your keys',
      ),
    ]);
  }

  List<Widget> _advancedRows() => <Widget>[
        const SizedBox(height: AppSpace.md),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.restore),
          title: 'Restore on a new phone',
          subtitle: 'Use your recovery phrase',
          chevron: true,
          onTap: () => _push(RestoreScreen(service: _svc, circles: _circles)),
        ),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.fact_check_outlined),
          title: 'Key history',
          subtitle: 'Spots a server that changes key history',
          chevron: true,
          onTap: () => _push(KeyLogScreen(service: _svc)),
        ),
      ];

  Widget _setupCard(LocalIdentity? id) => DsRowGroup(children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('This phone has no registered key', style: AppType.headline),
            const SizedBox(height: AppSpace.sm),
            const Text('Create the keys on this phone and register their public halves with the server. '
                'If your account already has keys, you will be asked to link this phone from your other phone or restore with your recovery phrase.'),
            const SizedBox(height: AppSpace.lg),
            DsPillButton(label: 'Create keys on this phone', icon: Icons.key, onPressed: _busy ? null : _setup),
          ]),
        ),
      ]);

  List<Widget> _deviceSection(LocalIdentity id) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return <Widget>[
      DigitBlock(digits: _digits.isEmpty ? '...' : _digits, label: 'This phone\'s fingerprint', copyLabel: 'Copy fingerprint'),
      const SizedBox(height: AppSpace.sm),
      Text('Short form: ${id.short}', style: AppType.secondary),
      Text('Created: ${formatDate(_myRecord!.createdAt)}', style: AppType.secondary),
      const SizedBox(height: AppSpace.md),
      if (_digits.isNotEmpty)
        Center(
          child: Semantics(
            label: 'QR code of this phone\'s fingerprint',
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(AppSpace.sm),
              child: QrImageView(data: 'Orbitly key\n$_digits', size: 168),
            ),
          ),
        ),
      const SizedBox(height: AppSpace.xs),
      Text(
        'Another person can scan this with any QR reader and read the numbers to '
        'compare them with this screen.',
        style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: AppSpace.lg),
      Text('Key storage: ${_store?.label ?? '...'}', key: const Key('keystore-level'), style: AppType.secondary),
      if (_store != null)
        Text(
          _store!.usableWhileLocked ? 'Keys available while locked' : 'Keys only work while the phone is unlocked',
          key: const Key('keystore-locked-state'),
          style: AppType.secondary,
        ),
      Text(
        defaultTargetPlatform == TargetPlatform.iOS
            ? 'Only the key that protects your private keys at rest lives in the iPhone Keychain '
                '(in the Secure Enclave when this iPhone has one). '
                'The encryption itself runs in the app, not in secure hardware.'
            : 'Only the key that protects your private keys at rest lives in the Android Keystore. '
                'The encryption itself runs in the app, not in secure hardware.',
        style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: AppSpace.lg),
      DsPillButton(
        label: 'Check my keys with the server',
        icon: Icons.fact_check,
        style: DsPillStyle.tonal,
        onPressed: _busy ? null : _checkServer,
      ),
      if (_check != null) ...<Widget>[
        const SizedBox(height: AppSpace.md),
        ServerRecordCard(check: _check!),
      ],
    ];
  }

  Widget _circleRow(_CircleRow r) {
    final CircleE2eeState? st = r.state;
    String sub;
    Widget? trailing;
    if (st == null) {
      sub = 'Status unavailable';
    } else if (st.isPrivate) {
      sub = 'Private';
      if (st.rekeyRequired) {
        sub = 'Private, new key needed';
        trailing = const DsStatusChip(label: 'Action needed', icon: Icons.warning_amber_rounded, color: Color(0xFFD97706));
      } else {
        trailing = const DsStatusChip(label: 'Private', icon: Icons.lock, color: Color(0xFF16A34A));
      }
    } else {
      sub = 'Normal circle';
    }
    return DsListRow(
      leading: DsListRow.iconTile(context, st?.isPrivate == true ? Icons.lock : Icons.lock_open),
      title: r.circle.name,
      subtitle: sub,
      trailing: trailing,
      chevron: true,
      onTap: st == null ? null : () => _push(EncryptionCircleScreen(circle: r.circle, service: _svc)),
    );
  }
}
