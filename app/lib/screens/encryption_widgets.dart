import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_trust.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

const TextStyle kMono = TextStyle(
  fontFamily: 'monospace',
  fontSize: 20,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.2,
  height: 1.5,
);

/// Large, copyable digit groups (4 groups per line). Shown for fingerprints and
/// safety numbers. Selectable so it can also be read out or pasted elsewhere.
class DigitBlock extends StatelessWidget {
  const DigitBlock({super.key, required this.digits, this.label, this.copyLabel = 'Copy'});
  final String digits;
  final String? label;
  final String copyLabel;

  @override
  Widget build(BuildContext context) {
    final List<String> g = digits.split(' ');
    final List<String> rows = <String>[
      for (int i = 0; i < g.length; i += 4) g.sublist(i, i + 4 > g.length ? g.length : i + 4).join('  ')
    ];
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '${label ?? 'Number'}: ${g.join(', ')}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ExcludeSemantics(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: SelectableText(rows.join('\n'), style: kMono.copyWith(color: cs.onSurface)),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: digits));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(copyLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// MATCH / MISMATCH result of "Check server record".
///
/// It states plainly what the check does NOT prove: the server is the party
/// being checked, so agreement shows consistency, not authenticity.
class ServerRecordCard extends StatelessWidget {
  const ServerRecordCard({super.key, required this.check});
  final ServerRecordCheck check;

  @override
  Widget build(BuildContext context) {
    final bool ok = check.match;
    final Color color = ok ? const Color(0xFF16A34A) : AppColors.sosRed;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String headline = ok
        ? 'MATCH'
        : (!check.registered ? 'NOT REGISTERED' : (check.revoked ? 'REVOKED' : 'MISMATCH'));
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Server record check: $headline',
      child: Container(
        key: const Key('server-record-card'),
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: color, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              Icon(ok ? Icons.check_circle : Icons.error, color: color, size: 32),
              const SizedBox(width: AppSpace.md),
              Expanded(child: Text(headline, key: const Key('server-record-verdict'), style: AppType.title.copyWith(color: color))),
            ]),
            const SizedBox(height: AppSpace.sm),
            if (ok)
              Text('The server holds exactly the keys this phone generated.', style: AppType.body.copyWith(color: cs.onSurface))
            else ...<Widget>[
              Text(check.problem ?? 'The server record does not match this phone.', style: AppType.body.copyWith(color: cs.onSurface)),
              const SizedBox(height: AppSpace.sm),
              Text(
                'What to do: do not trust this server for encrypted circles. '
                'Do not approve new members. Tell your family admin, compare the '
                'fingerprint below with "server e2ee-fingerprints" on the server, '
                'and re-register this phone\'s keys if the server record is wrong.',
                style: AppType.secondary.copyWith(color: cs.onSurface),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Text(
              'This proves the server tells the same story as this phone '
              '(consistency). It does NOT prove authenticity: a dishonest server '
              'would pass this check. Authenticity comes from comparing safety '
              'numbers with each person, in person.',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
            if (check.otherActive.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpace.md),
              Text('Other active keys on your account (${check.otherActive.length})', style: AppType.label),
              for (final k in check.otherActive)
                Text('${k.isRecovery ? 'Recovery phrase' : 'Device'}  ${k.short}', style: AppType.secondary),
              Text('If you do not recognise one of these, revoke it.', style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

/// A red or amber banner for a key-change / log alarm.
class AlarmBanner extends StatelessWidget {
  const AlarmBanner({super.key, required this.alarm, this.onDismiss});
  final E2eeAlarm alarm;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final Color color = alarm.severe ? AppColors.sosRed : const Color(0xFFD97706);
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${alarm.severe ? 'Warning' : 'Notice'}: ${alarm.title}',
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpace.md),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: color, width: alarm.severe ? 2 : 1),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Icon(alarm.severe ? Icons.gpp_bad : Icons.warning_amber_rounded, color: color),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(alarm.title, style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: AppSpace.xs),
              Text(alarm.body, style: AppType.secondary),
            ]),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
        ]),
      ),
    );
  }
}

/// "Verified" badge (local only; never sent anywhere).
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, required this.level});
  final TrustLevel level;

  @override
  Widget build(BuildContext context) {
    switch (level) {
      case TrustLevel.verified:
        return const DsStatusChip(label: 'Verified', icon: Icons.verified_user, color: Color(0xFF16A34A));
      case TrustLevel.verifiedChanged:
        return const DsStatusChip(label: 'KEY CHANGED', icon: Icons.gpp_bad, color: AppColors.sosRed);
      case TrustLevel.changed:
        return const DsStatusChip(label: 'Key changed', icon: Icons.warning_amber_rounded, color: Color(0xFFD97706));
      case TrustLevel.seen:
        return const DsStatusChip(label: 'Not verified', icon: Icons.help_outline);
      case TrustLevel.unseen:
        return const DsStatusChip(label: 'No key yet', icon: Icons.help_outline);
    }
  }
}

String formatDate(DateTime d) {
  final DateTime l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}
