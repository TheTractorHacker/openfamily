import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/lanes_service.dart' show LanesNotReady;
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/processing_widgets.dart';
import 'security_widgets.dart';

/// Admin action for a circle still in the old trusted-server mode: moves it to
/// per-member choice. Plain warnings first; the button stays off until the admin
/// ticks that they understood.
class LegacyUpgradeScreen extends StatefulWidget {
  const LegacyUpgradeScreen({super.key, required this.circle, this.controller});
  final Circle circle;
  final ProcessingController? controller;

  @override
  State<LegacyUpgradeScreen> createState() => _LegacyUpgradeScreenState();
}

class _LegacyUpgradeScreenState extends State<LegacyUpgradeScreen> {
  ProcessingController get _c => widget.controller ?? LanesProcessingController.instance;
  ProcessingSnapshot? _s;
  bool _loading = true;
  bool _busy = false;
  bool _understood = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _s == null;
      _error = null;
    });
    try {
      final ProcessingSnapshot s = await _c.load(widget.circle.id, force: true);
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

  Future<void> _upgrade() async {
    setState(() => _busy = true);
    try {
      await _c.upgradeLegacy(widget.circle.id);
      _done = true;
      _say('Circle upgraded');
    } on LanesNotReady catch (e) {
      _say('${e.names.join(', ')} must update the app first.');
    } catch (e) {
      _say(e is StateError ? e.message : errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _endLegacy() async {
    final bool ok = await showDsConfirm(context,
        title: ProcessingCopy.endLegacyTitle, message: ProcessingCopy.endLegacyBody, confirmLabel: 'End access', destructive: true);
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await _c.endLegacyAccess(widget.circle.id);
      _say('The server can no longer open old data');
    } catch (e) {
      _say(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upgrade circle')),
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
    if (!s.iAmAdmin) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.xl),
        child: ProcessingNote(
            noteKey: Key('upgrade-admin-only'),
            icon: Icons.lock_outline,
            text: 'Only a circle admin can upgrade this circle. Ask an admin to do it.'),
      );
    }
    final bool canRun = s.legacy && s.notReady.isEmpty && s.hasServerKey && _understood && !_busy;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: <Widget>[
        Text(widget.circle.name, style: AppType.headline),
        const SizedBox(height: AppSpace.sm),
        if (!s.legacy)
          ProcessingNote(
              noteKey: const Key('upgrade-not-legacy'),
              icon: Icons.check_circle_outline,
              text: _done
                  ? 'This circle now uses per-member choice. Nobody is opted in until they confirm on their own phone.'
                  : 'This circle is not in the old trusted-server mode.')
        else ...<Widget>[
          const ProcessingNote(noteKey: Key('upgrade-warning'), icon: Icons.warning_amber, color: AppColors.statusOrange, text: ProcessingCopy.upgradeBody),
          if (s.notReady.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Text(s.notReady.map((String n) => '$n\'s app is out of date and cannot use this yet.').join(' '),
                key: const Key('upgrade-not-ready'), style: AppType.secondary.copyWith(color: AppColors.statusRed)),
          ],
          if (!s.hasServerKey) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Text('This server has no approved server key for this circle.',
                key: const Key('upgrade-no-key'), style: AppType.secondary.copyWith(color: AppColors.statusRed)),
          ],
          const SizedBox(height: AppSpace.md),
          CheckboxListTile(
            key: const Key('upgrade-understood'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _understood,
            onChanged: _busy ? null : (bool? v) => setState(() => _understood = v ?? false),
            title: const Text('I understand this cannot be undone and the server keeps what it has already read.'),
          ),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(key: const Key('upgrade-run'), label: 'Upgrade circle', icon: Icons.upgrade, onPressed: canRun ? _upgrade : null),
        ],
        if (!s.legacy && s.iAmAdmin) ...<Widget>[
          const DsSectionHeader('Old data', padding: EdgeInsets.fromLTRB(0, AppSpace.xl, 0, AppSpace.xs)),
          const Text(
              'Only for circles that were upgraded from the old mode: the server can still open data from before the upgrade. '
              'You can end that once it has processed what you need.',
              style: AppType.secondary),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(
              key: const Key('upgrade-end-legacy'),
              label: 'End the server\'s access to old data',
              style: DsPillStyle.danger,
              icon: Icons.block,
              onPressed: _busy ? null : _endLegacy),
        ],
      ],
    );
  }
}
