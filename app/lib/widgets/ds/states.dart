import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'pill_button.dart';

/// Centered illustration-free message with optional action.
class _StateBody extends StatelessWidget {
  const _StateBody({
    required this.icon,
    required this.title,
    required this.message,
    this.iconColor,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 44, color: iconColor ?? cs.onSurfaceVariant),
              const SizedBox(height: AppSpace.md),
              Text(title, textAlign: TextAlign.center, style: AppType.headline),
              if (message != null) ...<Widget>[
                const SizedBox(height: AppSpace.xs),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: AppSpace.lg),
                DsPillButton(label: actionLabel!, onPressed: onAction),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DsEmptyState extends StatelessWidget {
  const DsEmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => _StateBody(
    icon: icon,
    title: title,
    message: message,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

class DsErrorState extends StatelessWidget {
  const DsErrorState({
    super.key,
    required this.message,
    this.title = 'Something went wrong',
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => _StateBody(
    icon: Icons.error_outline,
    iconColor: AppColors.statusOrange,
    title: title,
    message: message,
    actionLabel: onRetry == null ? null : 'Try again',
    onAction: onRetry,
  );
}

/// Full-width banner shown when the device cannot reach the server.
class DsOfflineBanner extends StatelessWidget {
  const DsOfflineBanner({
    super.key,
    this.message = 'You are offline',
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: brand.sheet,
        elevation: 3,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.sm,
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.cloud_off, color: AppColors.statusOrange),
              const SizedBox(width: AppSpace.md),
              Expanded(child: Text(message, style: AppType.secondary)),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
