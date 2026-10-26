import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A compact "Step X of Y" progress indicator shown across the whole
/// onboarding journey (sign-up, permissions, family, invite, locations).
///
/// Use it as an [AppBar.bottom]. Progress is shown as segments AND words, so
/// it never relies on colour alone, and the whole thing reads as one
/// semantic value to screen readers.
class OnboardingStepIndicator extends StatelessWidget
    implements PreferredSizeWidget {
  const OnboardingStepIndicator({
    super.key,
    required this.currentStep,
    this.totalSteps,
  });

  final int currentStep;

  /// Total steps in the journey. Null at a branch point (create vs. join)
  /// where the total depends on the path the user takes next.
  final int? totalSteps;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int? total = totalSteps;
    final String label =
        total == null ? 'Step $currentStep' : 'Step $currentStep of $total';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.xxl,
          0,
          AppSpace.xxl,
          AppSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              label,
              style: AppType.secondary.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurfaceVariant,
              ),
            ),
            if (total != null) ...<Widget>[
              const SizedBox(height: AppSpace.xs),
              Row(
                children: <Widget>[
                  for (int i = 1; i <= total; i++) ...<Widget>[
                    if (i > 1) const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: AnimatedContainer(
                        duration: AppMotion.of(context, AppMotion.fast),
                        height: 6,
                        decoration: BoxDecoration(
                          color: i <= currentStep
                              ? brand.accent
                              : cs.onSurface.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
