import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'pill_button.dart';

/// Confirmation dialog in the design system's voice.
///
/// Use [destructive] for actions that cannot be undone (delete account, log
/// out everywhere, remove a member): the confirm button takes the system's
/// danger style and the icon is a warning, so the stakes are never carried by
/// colour alone. The body scrolls and the buttons stack, so it holds up at
/// 200% text. Resolves to true only when the user confirms.
Future<bool> showDsConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext c) => _DsConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  );
  return ok == true;
}

class _DsConfirmDialog extends StatelessWidget {
  const _DsConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: BrandTheme.of(context).sheet,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpace.xl),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (destructive)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpace.md),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 36,
                    color: AppColors.sosRed,
                    semanticLabel: 'Warning',
                  ),
                ),
              Semantics(
                header: true,
                child: Text(title, style: AppType.title),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                message,
                style: AppType.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: AppSpace.xl),
              DsPillButton(
                label: confirmLabel,
                style: destructive ? DsPillStyle.danger : DsPillStyle.filled,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: AppSpace.sm),
              DsPillButton(
                label: cancelLabel,
                style: DsPillStyle.outlined,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
