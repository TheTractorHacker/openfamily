import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/join_service.dart';
import '../services/pending_invite.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// The join-a-family flow, reached from the map's `+` action sheet, the
/// family switcher's `+` chip, and onboarding.
///
/// Accepts an alphanumeric invite code and validates it against the server —
/// an invalid/unknown code shows a clear error (no false success).
class JoinCircleScreen extends StatefulWidget {
  const JoinCircleScreen({
    super.key,
    this.onDone,
    this.step,
    this.totalSteps = 4,
    this.initialCode,
  });

  /// Pre-fills the code field (from an invite link or QR code).
  final String? initialCode;

  /// When provided, called instead of popping on "Done" (used by onboarding
  /// so joining lands on the map).
  final VoidCallback? onDone;

  /// Onboarding step number (4 of 4). Null when reached outside onboarding.
  final int? step;

  /// Total onboarding steps for the join path (4: sign-up → permissions →
  /// create-or-join → join). The join path is shorter than the create path
  /// (6 steps), so the indicator must not claim "of 6" and then skip 5–6.
  final int totalSteps;

  @override
  State<JoinCircleScreen> createState() => _JoinCircleScreenState();
}

class _JoinCircleScreenState extends State<JoinCircleScreen> {
  final TextEditingController _code = TextEditingController();
  String? _error;
  bool _joined = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _code.text = widget.initialCode ?? PendingInvite.code ?? '';
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final String code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter your invite code');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final bool ok = await JoinService.join(code);
      if (!mounted) return;
      if (ok) PendingInvite.clear();
      setState(() {
        _submitting = false;
        if (ok) {
          _joined = true;
        } else {
          _error = 'That code isn\'t valid. Check it and try again.';
        }
      });
    } on SessionExpiredException {
      rethrow;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not join. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_joined) {
      return DsPage(
        title: 'Join a family',
        showBack: false,
        step: widget.step,
        totalSteps: widget.step == null ? null : widget.totalSteps,
        actions: <Widget>[
          DsPillButton(
            label: 'Done',
            onPressed: () {
              if (widget.onDone != null) {
                widget.onDone!();
              } else {
                Navigator.of(context).pop(true);
              }
            },
          ),
        ],
        children: <Widget>[
          const SizedBox(height: AppSpace.xxxl),
          Center(
            child: DsListRow.iconTile(context, Icons.check_circle_outline),
          ),
          const SizedBox(height: AppSpace.lg),
          const DsHeading(
            'Family joined',
            subtitle: 'You are now a member of the family.',
            center: true,
          ),
        ],
      );
    }
    return DsPage(
      title: 'Join a family',
      step: widget.step,
      totalSteps: widget.step == null ? null : widget.totalSteps,
      actions: <Widget>[
        DsBusyButton(label: 'Join', busy: _submitting, onPressed: _join),
      ],
      children: <Widget>[
        const DsHeading(
          'Enter your invite code',
          subtitle: 'Ask a family member for the invite code to join their '
              'family.',
        ),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.text,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _join(),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: const InputDecoration(
            labelText: 'Invite code',
            hintText: 'e.g. AB12CD34',
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }
}
