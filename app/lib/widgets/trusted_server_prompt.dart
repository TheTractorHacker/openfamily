import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/trusted_server_screen.dart' show kTrustedServerWarning;
import '../theme/app_theme.dart';

/// Remembers, per circle, that this person dismissed the trusted-server prompt.
class TrustedServerPromptStore {
  const TrustedServerPromptStore();
  static String _key(String circleId) => 'trusted_server_prompt_dismissed_$circleId';

  Future<bool> dismissed(String circleId) async =>
      (await SharedPreferences.getInstance()).getBool(_key(circleId)) ?? false;

  Future<void> dismiss(String circleId) async =>
      (await SharedPreferences.getInstance()).setBool(_key(circleId), true);
}

/// A dismissible notice on a Private circle: the admin recommends trusting the
/// server and this person has not allowed it yet. It only LEADS to the Trusted
/// server screen; nothing is ever consented from here.
class TrustedServerPrompt extends StatelessWidget {
  const TrustedServerPrompt({super.key, required this.onOpen, required this.onDismiss});
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    const Color color = Color(0xFFD97706);
    return Semantics(
      container: true,
      label: 'Notice: your server admin suggests trusting the server',
      child: Container(
        key: const Key('trusted-server-prompt'),
        margin: const EdgeInsets.only(bottom: AppSpace.md),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: color),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Icon(Icons.dns_outlined, color: color),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('Your server admin suggests trusting the server', style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: AppSpace.xs),
                const Text(
                  'Nothing has changed: the server still cannot read this circle. If you want it to, you can allow it '
                  'yourself on the Trusted server screen. Everyone in the circle has to allow it, and you can say no.',
                  style: AppType.secondary,
                ),
              ]),
            ),
            IconButton(
              key: const Key('trusted-server-prompt-dismiss'),
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(key: const Key('trusted-server-prompt-open'), onPressed: onOpen, child: const Text('Review')),
          ),
        ]),
      ),
    );
  }
}

enum PrivateModeChoice { trusted, strict }

/// Turn-on dialog for a Private circle when the admin recommends trusting the
/// server. "Server can read (trusted)" is preselected but only as a
/// recommendation; the honest warning is shown and strict end-to-end is one tap.
/// Choosing trusted still sends NO consent: the person is taken to the Trusted
/// server screen afterwards, where each member must allow it explicitly.
class PrivateModeChoiceDialog extends StatefulWidget {
  const PrivateModeChoiceDialog({super.key, required this.message});
  final String message;

  @override
  State<PrivateModeChoiceDialog> createState() => _PrivateModeChoiceDialogState();
}

class _PrivateModeChoiceDialogState extends State<PrivateModeChoiceDialog> {
  PrivateModeChoice _choice = PrivateModeChoice.trusted;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Make this a private circle?'),
      content: SingleChildScrollView(
        child: RadioGroup<PrivateModeChoice>(
          groupValue: _choice,
          onChanged: (PrivateModeChoice? v) => setState(() => _choice = v ?? _choice),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(widget.message),
            const SizedBox(height: AppSpace.md),
            const RadioListTile<PrivateModeChoice>(
              key: Key('choice-trusted'),
              value: PrivateModeChoice.trusted,
              title: Text('Server can read (trusted)'),
              subtitle: Text('Recommended by your server admin'),
            ),
            const RadioListTile<PrivateModeChoice>(
              key: Key('choice-strict'),
              value: PrivateModeChoice.strict,
              title: Text('Strict end-to-end encryption'),
              subtitle: Text('The server can never read this circle'),
            ),
            if (_choice == PrivateModeChoice.trusted) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              const Text(kTrustedServerWarning, key: Key('choice-warning'), style: AppType.secondary),
              const SizedBox(height: AppSpace.sm),
              const Text(
                'Choosing this does not allow anything yet. Next you review it on the Trusted server screen, and every member '
                'must allow it on their own phone.',
                style: AppType.secondary,
              ),
            ],
          ]),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('choice-confirm'),
          onPressed: () => Navigator.of(context).pop(_choice),
          child: const Text('Turn on'),
        ),
      ],
    );
  }
}
