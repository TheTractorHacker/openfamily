import 'package:flutter/material.dart';

import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/e2ee_models.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_trust.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'encryption_widgets.dart';
import 'security_widgets.dart';

/// The key transparency log: the pinned head, a fresh verification against the
/// server, and "compare log head" for catching a server that shows different
/// people different histories (split view).
class KeyLogScreen extends StatefulWidget {
  const KeyLogScreen({super.key, this.service});
  final E2eeService? service;

  @override
  State<KeyLogScreen> createState() => _KeyLogScreenState();
}

class _KeyLogScreenState extends State<KeyLogScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  LogHead? _head;
  String _digits = '';
  LogSync? _result;
  List<E2eeAlarm> _laneAlarms = <E2eeAlarm>[];
  bool _busy = false;
  String? _compareResult;
  final TextEditingController _peer = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshHead();
    _loadLaneAlarms();
  }

  @override
  void dispose() {
    _peer.dispose();
    super.dispose();
  }

  Future<void> _refreshHead() async {
    final LogHead? h = await _svc.trust.pinnedHead();
    final String d = h == null ? '' : await E2ee.digitGroups(h.hash);
    if (mounted) {
      setState(() {
        _head = h;
        _digits = d;
      });
    }
  }

  Future<void> _loadLaneAlarms() async {
    try {
      final List<E2eeAlarm> a = await _svc.laneAlarmList();
      if (mounted) setState(() => _laneAlarms = a);
    } catch (_) {}
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    try {
      final LogSync r = await _svc.syncLog();
      if (mounted) setState(() => _result = r);
      await _refreshHead();
      await _loadLaneAlarms();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compare() async {
    final List<String> parts = _peer.text.trim().split(':');
    final int? seq = parts.length == 2 ? int.tryParse(parts[0].trim()) : null;
    if (seq == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(parts[1].trim())) {
      setState(() => _compareResult = 'Enter it as  number:hash  exactly as shown on their phone.');
      return;
    }
    setState(() => _busy = true);
    try {
      final bool? same = await _svc.compareHead(seq, parts[1].trim());
      setState(() => _compareResult = same == null
          ? 'The server has no entry number $seq (yet).'
          : same
              ? 'SAME HISTORY - the server showed both of you the same log up to entry $seq.'
              : 'DIFFERENT - the server shows you another history than the one on their phone. Do not trust this server until you find out why.');
    } catch (e) {
      setState(() => _compareResult = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final LogHead? h = _head;
    final LogCheck? c = _result?.check;
    return Scaffold(
      appBar: AppBar(title: const Text('Key log')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(AppSpace.xl), children: <Widget>[
          const Text(
            'Every key registration, revocation and circle key change is entered in a log '
            'where each entry is signed by the phone that made it and chained to the one before. '
            'This phone remembers the newest entry it saw and checks that the server only ever adds to it.',
            style: AppType.secondary,
          ),
          const SizedBox(height: AppSpace.lg),
          for (final E2eeAlarm a in _laneAlarms)
            Padding(padding: const EdgeInsets.only(bottom: AppSpace.md), child: AlarmBanner(key: Key('lane-alarm-${a.circleId}'), alarm: a)),
          if (h == null)
            const Text('No log head pinned yet. Verify once to pin it.')
          else ...<Widget>[
            Text('Pinned head: entry ${h.seq}', style: AppType.headline),
            const SizedBox(height: AppSpace.sm),
            DigitBlock(digits: _digits, label: 'Log head', copyLabel: 'Copy digits'),
            const SizedBox(height: AppSpace.sm),
            SelectableText('${h.seq}:${h.hex}', key: const Key('head-token'), style: AppType.secondary.copyWith(fontFamily: 'monospace')),
            const Text('Read this token to another member; they paste it below.', style: AppType.secondary),
          ],
          const SizedBox(height: AppSpace.lg),
          DsPillButton(label: 'Verify the server\'s log now', icon: Icons.fact_check, onPressed: _busy ? null : _verify),
          if (c != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Semantics(
              liveRegion: true,
              child: Text(
                c.ok ? 'OK - the log only grew and every signature verifies.' : 'PROBLEM - ${c.detail}',
                key: const Key('log-verdict'),
                style: AppType.body.copyWith(fontWeight: FontWeight.w800, color: c.ok ? const Color(0xFF16A34A) : AppColors.sosRed),
              ),
            ),
            // What the new entries mean (owner approvals, resets, new keys).
            for (final E2eeAlarm a in _result!.alarms.where((E2eeAlarm a) => a.kind != AlarmKind.logProblem && a.seq != null))
              Padding(padding: const EdgeInsets.only(top: AppSpace.md), child: AlarmBanner(alarm: a)),
          ],
          const DsSectionHeader('Compare with another member', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          const Text(
            'A server could show you and a family member different histories. If both phones '
            'hold the same entry hash at the same number, you were shown the same log.',
            style: AppType.secondary,
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: _peer,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Their token (number:hash)'),
          ),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(label: 'Compare', style: DsPillStyle.tonal, onPressed: _busy ? null : _compare),
          if (_compareResult != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Semantics(liveRegion: true, child: Text(_compareResult!, key: const Key('compare-result'), style: AppType.body)),
          ],
        ]),
      ),
    );
  }
}
