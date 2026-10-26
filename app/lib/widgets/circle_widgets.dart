import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../theme/app_theme.dart';
import 'ds/ds.dart';

/// Emoji offered when creating or editing a circle's icon.
const List<String> kCircleIcons = <String>[
  '👪', '🏠', '👫', '🎓', '⚽', '🎒', '🐶', '🌳', '✈️', '💼', '🎉', '❤️',
];

/// Round avatar showing a circle's icon, or a generic group glyph.
class CircleIconAvatar extends StatelessWidget {
  const CircleIconAvatar({super.key, required this.circle, this.size = 44});

  final Circle circle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: brand.accent.withValues(alpha: 0.25),
        ),
        child: circle.icon != null
            ? Text(circle.icon!, style: TextStyle(fontSize: size * 0.5))
            : Icon(Icons.group_outlined,
                color: brand.accentInk, size: size * 0.55),
      ),
    );
  }
}

/// "Admin" / "Member" pill. Colour is never the only signal: the label is text.
class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key, required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final bool admin = role == 'admin';
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: admin
            ? brand.accent.withValues(alpha: 0.28)
            : scheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        admin ? 'Admin' : 'Member',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}

/// Full-area message with an optional retry, for error / offline / empty.
class CircleStateMessage extends StatelessWidget {
  const CircleStateMessage({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height * 0.5,
        ),
        child: DsEmptyState(
          icon: icon,
          title: title,
          message: body,
          actionLabel: onAction == null ? null : (actionLabel ?? 'Try again'),
          onAction: onAction,
        ),
      ),
    );
  }
}
