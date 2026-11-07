import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/join_service.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/pending_invite.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/processing_widgets.dart';

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
    this.previewLoader,
  });

  /// Injected in tests; defaults to `GET /invites/{code}/preview`.
  final Future<InvitePreview?> Function(String code)? previewLoader;

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
    _schedulePreview(immediate: true);
  }

  InvitePreview? _preview;
  Timer? _debounce;
  int _previewSeq = 0;

  void _schedulePreview({bool immediate = false}) {
    _debounce?.cancel();
    final String code = _code.text.trim();
    if (code.length < 4) {
      if (_preview != null) setState(() => _preview = null);
      return;
    }
    _debounce = Timer(immediate ? Duration.zero : const Duration(milliseconds: 500), () async {
      final int seq = ++_previewSeq;
      InvitePreview? p;
      try {
        p = await (widget.previewLoader ?? JoinService.preview)(code);
      } catch (_) {}
      if (mounted && seq == _previewSeq) setState(() => _preview = p);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
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
      if (ok) {
        await InviteAnchor.save(PendingInvite.current.value?.fingerprint);
        PendingInvite.clear();
      }
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
            _schedulePreview();
          },
          decoration: const InputDecoration(
            labelText: 'Invite code',
            hintText: 'e.g. AB12CD34',
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        if (_error != null) DsMessage(_error!),
        const SizedBox(height: AppSpace.lg),
        _setupNote(),
      ],
    );
  }

  /// One honest line about how the circle behind the code processes data. Without a
  /// preview (unknown code, offline, old server) the generic note stays.
  Widget _setupNote() {
    final InvitePreview? p = _preview;
    String text;
    if (p == null) {
      text = 'If the circle is a Private circle, its admin may allow server processing. You then choose for your own data '
          'after joining, and the safe choice (Phone only) is equal to the other. Some circles require server processing; '
          'in that case you will be asked to give your own consent or leave. The server operator can read the data of '
          'members who allow it.';
    } else if (!p.isPrivate) {
      text = 'This is a normal circle, not a Private circle: your position is sent to the server in readable form.';
    } else if (p.legacy) {
      text = 'Private circle in the OLD trusted-server mode: the server holds the circle key and can read this circle, and it keeps readable '
          'copies, while every member has allowed it. This is not end-to-end encryption against the server. An admin can upgrade the circle '
          'so that each member decides for themselves.';
    } else if (!p.serverAssist) {
      text = 'Private circle. Server processing: off. Your phone does the processing and the server cannot read your location.';
    } else if (p.required) {
      text = 'Private circle. Server processing: required. To take part you must give your own consent on your phone to let the '
          'server read your location, trips and driving data, otherwise you cannot share with this circle. Anyone who runs or backs '
          'up this server can read the data of members who allow it.';
    } else {
      text = 'Private circle. Server processing: on, you choose. After joining you decide for your own data; '
          '"${p.defaultServer ? 'Server processing' : 'Phone only'}" is suggested, but nothing is shared with the server unless you confirm it. '
          'Anyone who runs or backs up this server can read the data of members who allow it.';
    }
    return ProcessingNote(noteKey: const Key('join-processing-note'), icon: Icons.info_outline, text: text);
  }
}
