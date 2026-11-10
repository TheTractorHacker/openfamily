import 'package:flutter/foundation.dart' show TargetPlatform, debugPrint, defaultTargetPlatform;
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

  /// What failed, so the error state can name the cause (see describeError).
  Object? _errorCause;
  ServerRecordCheck? _check;
  List<_CircleRow> _rows = <_CircleRow>[];
  List<E2eeAlarm> _alarms = <E2eeAlarm>[];
  KeystoreStatus? _store;

  /// A key this phone had before (archived by "Set this phone up again" or an account switch) that still opens.
  VaultArchiveSet? _restorable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Set when this phone's own key cannot be used (the screen then offers the repair).
  LocalKeyProblem? _keyProblem;

  /// The exception behind [_keyProblem] (its cause decides the wording and whether the owner-note repair is offered).
  LocalKeyException? _keyError;

  /// What the last "Repair" tap found, in words.
  String? _repairNote;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorCause = null;
      _keyProblem = null;
      _keyError = null;
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
      VaultArchiveSet? restorable;
      if (id == null) {
        try {
          restorable = await _svc.restorableIdentity();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _restorable = restorable;
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
        _keyProblem = LocalKeyProblem.invalidated;
        _error = 'This phone\'s key storage was reset (for example the screen lock was removed). '
            'The private keys cannot be read any more. Set this phone up again, then restore with your recovery phrase '
            'or link it from your other phone.';
      });
    } on LocalKeyException catch (e) {
      // Stored but unreadable: not a network problem, and Retry alone will not fix it. Say what is wrong when it is
      // known (the cause is also in the storage events and the Diagnostics report), and offer the way out.
      debugPrint('encryption keys: ${e.toString()}');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _keyProblem = e.problem;
        _keyError = e;
        _error = e.problem == LocalKeyProblem.locked
            ? e.message
            : (e.whatIsWrong.isNotEmpty ? e.whatIsWrong : e.screenMessage);
      });
    } on VaultLockedException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _keyProblem = LocalKeyProblem.locked;
        _error = const LocalKeyException(LocalKeyProblem.locked).message;
        _errorCause = const LocalKeyException(LocalKeyProblem.locked);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorText(e);
        _errorCause = e;
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
      await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => LinkDeviceScreen(service: _svc, role: LinkRole.newPhone)));
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePrevious() async {
    final VaultArchiveSet? set = _restorable;
    if (set == null) return;
    setState(() => _busy = true);
    try {
      await _svc.restoreArchivedIdentity(set);
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
                ? (_keyProblem == LocalKeyProblem.unreadable || _keyProblem == LocalKeyProblem.invalidated
                    ? _repairView()
                    : (_errorCause != null
                    ? LoadStateView.forError(_errorCause!, onRetry: _load)
                    : LoadStateView(error: _error, offline: false, onRetry: _load)))
                : _body(),
      ),
    );
  }

  Widget _body() {
    final LocalIdentity? id = _id;
    final double gutter = DsListRow.compactFor(context) ? AppSpace.md : AppSpace.lg;
    return RefreshIndicator(
      onRefresh: _load,
      // Same body as a DsSettingsList, but the list must always be pullable.
      child: DsBody(
        child: DsRowScope(
          inset: DsRowScope.insetFor(context),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(gutter, AppSpace.sm, gutter, AppSpace.xxl),
            children: <Widget>[
              for (final E2eeAlarm a in _alarms) AlarmBanner(alarm: a),
              if (id == null || _myRecord == null) _setupCard(id) else _statusCard(),
              if (id != null && _myRecord != null) ...<Widget>[
                const DsSectionHeader('Recovery and devices'),
                DsRowGroup(children: <Widget>[
                  DsListRow(
                    key: const Key('keys-recovery'),
                    leading: DsListRow.iconTile(context, Icons.pin_outlined, decorative: true),
                    title: 'Recovery phrase',
                    subtitle: 'Get your circles back',
                    info: 'Write down 24 words to get your encrypted circles back on a new phone. '
                        'If you lose every phone and the recovery phrase, the encrypted data of your private circles '
                        'cannot be recovered by anyone, including the server operator.',
                    chevron: true,
                    onTap: () => _push(RecoverySetupScreen(service: _svc)),
                  ),
                  DsListRow(
                    key: const Key('keys-link'),
                    leading: DsListRow.iconTile(context, Icons.phonelink_setup, decorative: true),
                    title: 'Link another phone',
                    subtitle: 'Add a new phone',
                    info: 'Use this on a new phone, or to approve a new phone from this one. '
                        'You will need both phones in front of you.',
                    chevron: true,
                    onTap: () => _push(LinkDeviceScreen(service: _svc)),
                  ),
                ]),
              ],
              if (_rows.isNotEmpty) ...<Widget>[
                const DsSectionHeader('Circles'),
                DsRowGroup(children: <Widget>[for (final _CircleRow r in _rows) _circleRow(r)]),
              ],
              if (id != null && _myRecord != null) ...<Widget>[
                const SizedBox(height: AppSpace.xl),
                DsRowGroup(children: <Widget>[
                  Theme(
                    data: Theme.of(context).copyWith(
                      dividerColor: Colors.transparent,
                      // Title on the same x as the other rows: tile (40) + 12.
                      listTileTheme: Theme.of(context).listTileTheme.copyWith(horizontalTitleGap: AppSpace.md, minLeadingWidth: 40),
                    ),
                    child: ExpansionTile(
                      key: const Key('keys-advanced'),
                      tilePadding: EdgeInsets.symmetric(horizontal: DsRowScope.insetFor(context)),
                      leading: DsListRow.compactFor(context)
                          ? null
                          : DsListRow.iconTile(context, Icons.settings_outlined, decorative: true),
                      title: const Text('Advanced', style: AppType.body),
                      subtitle: Text('Fingerprint, key storage, checks',
                          style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      childrenPadding: const EdgeInsets.only(bottom: AppSpace.sm),
                      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Divider(height: 1, indent: DsRowScope.insetFor(context), color: Theme.of(context).colorScheme.outlineVariant),
                        const SizedBox(height: AppSpace.md),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: DsRowScope.insetFor(context)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _deviceSection(id)),
                        ),
                        ..._advancedRows(),
                      ],
                    ),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard() {
    final bool lockedOk = _store?.usableWhileLocked ?? true;
    return DsRowGroup(children: <Widget>[
      DsListRow(
        key: const Key('keys-status'),
        leading: DsListRow.iconTile(context, Icons.verified_user_outlined, decorative: true),
        title: 'Keys are safe on this phone',
        subtitle: lockedOk ? 'Works with the screen locked' : 'Unlock the phone once to finish updating',
        info: 'Private circles are end-to-end encrypted: the keys are made on this phone and never leave it. '
            'The server only stores public keys and scrambled copies it cannot read.',
        infoTitle: 'Your keys',
      ),
    ]);
  }

  List<Widget> _advancedRows() => <Widget>[
        const SizedBox(height: AppSpace.md),
        Divider(height: 1, indent: DsRowScope.insetFor(context), color: Theme.of(context).colorScheme.outlineVariant),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.restore, decorative: true),
          title: 'Restore on a new phone',
          subtitle: 'Use your recovery phrase',
          chevron: true,
          onTap: () => _push(RestoreScreen(service: _svc, circles: _circles)),
        ),
        Divider(height: 1, indent: DsRowScope.insetFor(context), color: Theme.of(context).colorScheme.outlineVariant),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.fact_check_outlined, decorative: true),
          title: 'Key history',
          subtitle: 'Spots a server that changes key history',
          chevron: true,
          onTap: () => _push(KeyLogScreen(service: _svc)),
        ),
      ];

  /// This phone's stored key cannot be read. When the cause is known the screen says what is wrong in plain words;
  /// "Try again" re-runs the check (and the automatic repair of the account note); the way out of last resort is to
  /// put the unreadable copy aside and set the phone up again (restore with the recovery phrase, link from another
  /// phone, or new keys).
  Widget _repairView() {
    final bool ownerNote = _keyError?.ownerRepairable ?? false;
    final bool intact = _keyError?.keyIntact ?? false;
    return ListView(
      padding: EdgeInsets.all(DsListRow.compactFor(context) ? AppSpace.md : AppSpace.lg),
      children: <Widget>[
        Text(ownerNote ? 'This phone lost the note of which account its key belongs to' : "This phone's encryption key can't be read",
            key: const Key('keys-repair-title'), style: AppType.headline),
        const SizedBox(height: AppSpace.sm),
        Text(_error ?? ''),
        if (ownerNote) ...<Widget>[
          const SizedBox(height: AppSpace.sm),
          const Text(
              'Repair writes that note again, but only after the server confirms that this phone\'s key belongs to your '
              'account. The key itself is never touched.',
              style: AppType.secondary),
        ],
        if (_repairNote != null) ...<Widget>[
          const SizedBox(height: AppSpace.sm),
          Text(_repairNote!, key: const Key('keys-repair-note')),
        ],
        const SizedBox(height: AppSpace.sm),
        const Text(
            'Right after an app update or a restart this can be temporary: tap Try again first, or restart the phone. '
            'Nothing is deleted while you wait.',
            style: AppType.secondary),
        const SizedBox(height: AppSpace.lg),
        if (ownerNote) ...<Widget>[
          DsPillButton(
            key: const Key('keys-repair-owner'),
            label: 'Repair',
            icon: Icons.build_outlined,
            onPressed: _busy ? null : _repairOwner,
          ),
          const SizedBox(height: AppSpace.sm),
        ],
        DsPillButton(label: 'Try again', icon: Icons.refresh, onPressed: _busy ? null : _load),
        const SizedBox(height: AppSpace.lg),
        Text(
            intact
                ? 'Only if nothing above helps: set this phone up again, then restore with your recovery phrase or link it '
                    'from your other phone. The stored key is put aside, not deleted.'
                : 'If Try again does not help, set this phone up again, then restore with your recovery phrase or link it '
                    'from your other phone.',
            style: AppType.secondary),
        const SizedBox(height: AppSpace.sm),
        DsPillButton(
          key: const Key('keys-repair-reset'),
          label: 'Set this phone up again',
          icon: Icons.build_outlined,
          onPressed: _busy ? null : _repair,
        ),
      ],
    );
  }

  /// "Repair": writes the account note again once the server confirms this phone's key (see
  /// [E2eeService.repairOwnerRecord]). Never changes the key.
  Future<void> _repairOwner() async {
    setState(() {
      _busy = true;
      _repairNote = null;
    });
    OwnerRepair r;
    try {
      r = await _svc.repairOwnerRecord();
    } catch (e) {
      debugPrint('encryption keys: owner repair failed (${e.runtimeType})');
      r = OwnerRepair.offline;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _repairNote = switch (r) {
        OwnerRepair.repaired || OwnerRepair.notNeeded => null,
        OwnerRepair.offline => 'The server could not be asked just now, so nothing was changed. Check the connection and tap Repair again.',
        OwnerRepair.notOurs => 'Your account does not list this phone\'s key as active, so nothing was changed. '
            'Use Set this phone up again, then restore or link this phone.',
        OwnerRepair.otherAccount => 'The key on this phone belongs to another account, so nothing was changed.',
        OwnerRepair.noAccount => 'The app could not tell which account is signed in. Sign in again, then tap Repair.',
        OwnerRepair.noKey => 'The stored key could not be checked, so nothing was changed.',
      };
    });
    if (r == OwnerRepair.repaired || r == OwnerRepair.notNeeded) await _load();
  }

  Future<void> _repair() async {
    final bool ok = await showDsConfirm(
      context,
      title: 'Set this phone up again?',
      message: 'The key stored on this phone cannot be read, so it is put aside on this phone (kept, not deleted, so it '
          'can be brought back if it becomes readable again). The copy kept for reinstalls (see Settings, Security) is '
          'not deleted: if the server still lists that key, this phone gets the very same key back by itself. Nothing is '
          'deleted on the server. Otherwise, restore with your recovery phrase or link this phone from your other phone, so it gets your '
          'circles back. If neither is possible, create new keys: the other members will see that your key changed, and '
          'an admin shares the circle keys with this phone again.',
      confirmLabel: 'Remove and set up',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await _svc.eraseLocalKeys(keepReinstallCopy: true);
    } catch (e) {
      debugPrint('encryption keys: erase failed (${e.runtimeType})');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Widget _setupCard(LocalIdentity? id) => DsRowGroup(children: <Widget>[
        Padding(
          padding: EdgeInsets.all(DsRowScope.insetFor(context)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('This phone has no registered key', style: AppType.headline),
            const SizedBox(height: AppSpace.sm),
            const Text('Create the keys on this phone and register their public halves with the server. '
                'If your account already has keys, you will be asked to link this phone from your other phone or restore with your recovery phrase.'),
            const SizedBox(height: AppSpace.lg),
            if (id == null && _restorable != null) ...<Widget>[
              DsPillButton(
                key: const Key('keys-restore-previous'),
                label: 'Bring back the key this phone had before',
                icon: Icons.settings_backup_restore,
                onPressed: _busy ? null : _restorePrevious,
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            DsPillButton(label: 'Create keys on this phone', icon: Icons.key, onPressed: _busy ? null : _setup),
            const SizedBox(height: AppSpace.sm),
            DsPillButton(
              key: const Key('keys-setup-restore'),
              label: 'Restore with recovery phrase',
              icon: Icons.restore,
              onPressed: _busy ? null : () => _push(RestoreScreen(service: _svc, circles: _circles)),
            ),
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
      leading: DsListRow.iconTile(context, st?.isPrivate == true ? Icons.lock : Icons.lock_open, decorative: true),
      title: r.circle.name,
      subtitle: sub,
      trailing: trailing,
      chevron: true,
      onTap: st == null ? null : () => _push(EncryptionCircleScreen(circle: r.circle, service: _svc)),
    );
  }
}
