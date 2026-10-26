import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/invite_service.dart';
import '../services/server_config.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// The "Invite" step: explain inviting, then "Send Code" generates an
/// alphanumeric code and opens the native share sheet (pick a share app →
/// send). The code is also tap-to-copy.
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
  });

  final String? circleName;
  final VoidCallback? onDone;
  final String doneLabel;

  /// Onboarding step number (5 of 6). Null when reached outside onboarding.
  final int? step;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _code;
  bool _creating = false;
  String? _error;

  Future<void> _sendCode() async {
    String code = _code ?? '';
    if (code.isEmpty) {
      setState(() {
        _creating = true;
        _error = null;
      });
      try {
        code = await InviteService.createCode();
      } catch (_) {
        if (mounted) {
          setState(() {
            _creating = false;
            _error = 'Could not create an invite code. Check your '
                'connection and try again.';
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _creating = false;
        _code = code;
      });
    }
    try {
      await Share.share(
        InviteService.shareMessage(code),
        subject: InviteService.shareSubject,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the share sheet')),
        );
      }
    }
  }

  Future<void> _copyCode() async {
    final String? code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
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
        DsBusyButton(
          label: hasCode ? 'Share code' : 'Create invite code',
          icon: hasCode ? Icons.ios_share : Icons.person_add_alt_1,
          busy: _creating,
          onPressed: _sendCode,
        ),
        if (hasCode)
          DsPillButton(
            label: 'Copy code',
            icon: Icons.copy,
            style: DsPillStyle.tonal,
            onPressed: _copyCode,
          ),
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
