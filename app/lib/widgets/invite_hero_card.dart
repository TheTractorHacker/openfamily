import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shown in the People list when you are the only person in the circle, which
/// is the moment a family app is least useful. One tap sends an invite link
/// that installs the app and joins the circle; the code/QR screen stays one
/// tap away for people who would rather read a code out loud.
class InviteHeroCard extends StatefulWidget {
  const InviteHeroCard({
    super.key,
    required this.onSend,
    required this.onShowCode,
  });

  /// Creates an invite and opens the share sheet. The card shows a spinner
  /// until it completes.
  final Future<void> Function() onSend;

  /// Opens the invite code / QR screen.
  final VoidCallback onShowCode;

  @override
  State<InviteHeroCard> createState() => _InviteHeroCardState();
}

class _InviteHeroCardState extends State<InviteHeroCard> {
  bool _busy = false;

  Future<void> _send() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSend();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.md,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              cs.primary.withValues(alpha: 0.22),
              cs.primary.withValues(alpha: 0.06),
            ],
          ),
          border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _EmptySeats(),
              const SizedBox(height: AppSpace.md),
              Text(
                'Your family isn’t on the map yet',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Send one link. It installs OpenFamily and puts them in your '
                'circle, no codes to type.',
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _send,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                  label: const Text('Send invite link'),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _busy ? null : widget.onShowCode,
                  child: const Text('Show code or QR instead'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three overlapping dashed circles with a plus: the seats waiting for family.
class _EmptySeats extends StatelessWidget {
  const _EmptySeats();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    const double size = 44;
    const double step = 30;
    return ExcludeSemantics(
      child: SizedBox(
        height: size,
        width: size + step * 2,
        child: Stack(
          children: <Widget>[
            for (int i = 2; i >= 0; i--)
              PositionedDirectional(
                start: step * i,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surface,
                    border: Border.all(
                      color: cs.primary.withValues(alpha: 0.7),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    i == 0 ? Icons.add_rounded : Icons.person_outline_rounded,
                    color: cs.primary,
                    size: 22,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
