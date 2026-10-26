import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/invite_service.dart';
import '../services/server_config.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// The "Invite" step: "Create invite code" asks the server for a code and
/// shows it on screen with a Copy button; the share sheet is optional.
///
/// Used by both the map's `+` → Invite flow and onboarding (where [onDone]
/// continues to the next step).
class InviteScreen extends StatefulWidget {
  const InviteScreen({
    super.key,
    this.circleName,
    this.onDone,
    this.doneLabel = 'Done',
    this.step,
    this.createCode,
    this.shareCode,
  });

  final String? circleName;
  final VoidCallback? onDone;
  final String doneLabel;

  /// Onboarding step number (5 of 6). Null when reached outside onboarding.
  final int? step;

  /// Creates a code on the server. Defaults to [InviteService.createCode];
  /// injectable for tests.
  final Future<String> Function()? createCode;

  /// Opens the share sheet with the message. Defaults to `Share.share`;
  /// injectable for tests.
  final Future<void> Function(String message, String subject)? shareCode;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _code;
  bool _creating = false;
  String? _error;

  /// Creates the code (once). The code is put on screen before anything else
  /// happens; sharing is a separate, optional step.
  Future<void> _create() async {
    if (_creating || _code != null) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final String code =
          await (widget.createCode ?? InviteService.createCode)();
      if (!mounted) return;
      setState(() {
        _creating = false;
        _code = code;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = describeInviteError(e);
      });
    }
  }

  Future<void> _share() async {
    final String? code = _code;
    if (code == null) return;
    try {
      final Future<void> Function(String, String) share = widget.shareCode ??
          (String m, String s) => Share.share(m, subject: s);
      await share(InviteService.shareMessage(code), InviteService.shareSubject);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open the share sheet. Your code is on screen: '
              'tap Copy code and paste it in a message.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _copyCode() async {
    final String? code = _code;
    if (code == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: code));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied to clipboard')),
    );
  }

  void _done() {
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final String circle = widget.circleName ?? 'your family';
    final bool hasCode = _code != null;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BrandTheme brand = BrandTheme.of(context);
    return DsPage(
      title: 'Invite',
      step: widget.step,
      totalSteps: widget.step == null ? null : 6,
      actions: <Widget>[
        if (!hasCode)
          DsBusyButton(
            label: _error == null ? 'Create invite code' : 'Try again',
            icon: Icons.person_add_alt_1,
            busy: _creating,
            onPressed: _create,
          )
        else ...<Widget>[
          DsPillButton(
            label: 'Copy code',
            icon: Icons.copy,
            onPressed: _copyCode,
          ),
          DsPillButton(
            label: 'Share code',
            icon: Icons.ios_share,
            style: DsPillStyle.tonal,
            onPressed: _share,
          ),
        ],
        DsPillButton(
          label: widget.doneLabel,
          style: hasCode ? DsPillStyle.outlined : DsPillStyle.tonal,
          onPressed: _done,
        ),
      ],
      children: <Widget>[
        DsHeading(
          hasCode ? 'Your invite code' : 'Invite your family',
          subtitle: hasCode
              ? 'Share it so your family can join $circle. Read it out loud '
                  'or send it in a message.'
              : 'Share a code so your family can join $circle and appear on '
                  'your map.',
        ),
        if (hasCode) ...<Widget>[
          Semantics(
            container: true,
            label: 'Invite code ${_code!.split('').join(' ')}',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpace.xxl,
                horizontal: AppSpace.lg,
              ),
              decoration: BoxDecoration(
                color: brand.sheet,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Column(
                children: <Widget>[
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _code!,
                      style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 8,
                        color: brand.accentInk,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    ServerConfig.instance.apiBaseUrl,
                    textAlign: TextAlign.center,
                    style: AppType.secondary
                        .copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          // Reserved for issue #40: a QR code and a tap-to-join link for this
          // invite. Keep this slot between the code and the actions.
          const KeyedSubtree(
            key: Key('invite-qr-slot'),
            child: SizedBox.shrink(),
          ),
        ] else
          Center(
            child: ExcludeSemantics(
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: brand.accent,
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
                child: Icon(
                  Icons.person_add_alt_1,
                  size: 56,
                  color: brand.onAccent,
                ),
              ),
            ),
          ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }
}
