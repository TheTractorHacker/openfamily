import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_trust.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_widgets.dart';
import 'security_widgets.dart';

/// Safety number with one person, the local "Verified" state and a key-change
/// warning. Verification is stored only on this phone.
class MemberSafetyScreen extends StatefulWidget {
  const MemberSafetyScreen({super.key, required this.userId, required this.name, this.service});
  final String userId;
  final String name;
  final E2eeService? service;

  @override
  State<MemberSafetyScreen> createState() => _MemberSafetyScreenState();
}

class _MemberSafetyScreenState extends State<MemberSafetyScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  String? _number;
  List<DeviceKey> _theirs = <DeviceKey>[];
  TrustAssessment? _trust;
  String? _error;
  bool _loading = true;
  final TextEditingController _typed = TextEditingController();
  bool? _typedMatches;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _svc.safetyWith(widget.userId);
      if (!mounted) return;
      setState(() {
        _number = r.number;
        _theirs = r.theirs;
        _trust = r.trust;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorText(e);
      });
    }
  }

  void _compare() {
    final String typed = _typed.text.replaceAll(RegExp(r'[^0-9]'), '');
    final String mine = (_number ?? '').replaceAll(' ', '');
    setState(() => _typedMatches = typed.length == mine.length && E2ee.constEq(typed.codeUnits, mine.codeUnits));
  }

  @override
  Widget build(BuildContext context) {
    final TrustAssessment? t = _trust;
    return Scaffold(
      appBar: AppBar(title: Text('Verify ${widget.name}', overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? LoadStateView(error: _error, offline: false, onRetry: _load)
                : ListView(padding: const EdgeInsets.all(AppSpace.xl), children: <Widget>[
                    if (t != null && t.level == TrustLevel.verifiedChanged)
                      AlarmBanner(
                        alarm: E2eeAlarm(AlarmKind.verifiedKeyChanged, '${widget.name}\'s key CHANGED',
                            'You verified ${widget.name} before and their keys are different now. Do not trust them '
                            'until you compare the new safety number in person.'),
                      ),
                    if (t != null && t.level == TrustLevel.changed)
                      AlarmBanner(
                        alarm: E2eeAlarm(AlarmKind.keyChanged, '${widget.name}\'s key changed',
                            'This is not a key you verified, but it is different from the one this phone saw before.'),
                      ),
                    Row(children: <Widget>[
                      Expanded(child: Text('Safety number with ${widget.name}', style: AppType.headline)),
                      VerifiedBadge(level: t?.level ?? TrustLevel.unseen),
                    ]),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      'Meet ${widget.name}, or call a number you already trust, and read these digits to each other. '
                      'If every group matches on both phones, the keys are genuine and no one is in between. '
                      'The server cannot do this check for you.',
                      style: AppType.secondary,
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DigitBlock(digits: _number ?? '', label: 'Safety number', copyLabel: 'Copy number'),
                    const SizedBox(height: AppSpace.md),
                    Center(
                      child: Semantics(
                        label: 'QR code of the safety number',
                        child: Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(AppSpace.sm),
                          child: QrImageView(data: 'OpenFamily safety number\n${_number ?? ''}', size: 168),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    TextField(
                      controller: _typed,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Type or paste the number from their phone',
                        helperText: 'Compared on this phone only',
                      ),
                      onChanged: (_) => setState(() => _typedMatches = null),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    DsPillButton(label: 'Compare', icon: Icons.compare_arrows, style: DsPillStyle.tonal, onPressed: _compare),
                    if (_typedMatches != null) ...<Widget>[
                      const SizedBox(height: AppSpace.sm),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _typedMatches! ? 'MATCH - the numbers are identical.' : 'DOES NOT MATCH - do not verify. Someone may be intercepting.',
                          style: AppType.body.copyWith(
                              fontWeight: FontWeight.w800,
                              color: _typedMatches! ? const Color(0xFF16A34A) : AppColors.sosRed),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpace.xl),
                    if (t?.level == TrustLevel.verified)
                      DsPillButton(
                        label: 'Remove verification',
                        style: DsPillStyle.outlined,
                        onPressed: () async {
                          await _svc.trust.clearVerified(widget.userId);
                          await _load();
                        },
                      )
                    else
                      DsPillButton(
                        label: 'Mark as verified',
                        icon: Icons.verified_user,
                        onPressed: () async {
                          await _svc.markVerified(widget.userId);
                          await _load();
                        },
                      ),
                    const SizedBox(height: AppSpace.lg),
                    Text('${widget.name}\'s keys (${_theirs.length})', style: AppType.label),
                    for (final DeviceKey k in _theirs)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpace.xs),
                        child: Text(
                          '${k.isRecovery ? 'Recovery phrase' : 'Device'}  ${k.short}  since ${formatDate(k.createdAt)}'
                          '${k.isRoot ? '' : '  (added by another of their keys)'}',
                          style: AppType.secondary,
                        ),
                      ),
                  ]),
      ),
    );
  }
}
