import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../onboarding_step_indicator.dart';
import 'pill_button.dart';

/// Standard page for forms and onboarding steps: app bar (optionally with the
/// onboarding step indicator), a scrolling body capped to a readable width,
/// and an optional pinned action area that stays above the keyboard and never
/// overlaps text at large font sizes.
class DsPage extends StatelessWidget {
  const DsPage({
    super.key,
    required this.title,
    required this.children,
    this.actions = const <Widget>[],
    this.step,
    this.totalSteps,
    this.showBack = true,
    this.appBarActions,
    this.maxWidth = 520,
  });

  final String title;
  final List<Widget> children;

  /// Pinned under the body (primary action first).
  final List<Widget> actions;

  /// Onboarding step number; null outside onboarding.
  final int? step;
  final int? totalSteps;
  final bool showBack;
  final List<Widget>? appBarActions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: showBack,
        actions: appBarActions,
        bottom: step == null
            ? null
            : OnboardingStepIndicator(
                currentStep: step!,
                totalSteps: totalSteps,
              ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.xxl,
                      AppSpace.lg,
                      AppSpace.xxl,
                      AppSpace.lg,
                    ),
                    children: children,
                  ),
                ),
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.xxl,
                      AppSpace.sm,
                      AppSpace.xxl,
                      AppSpace.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (int i = 0; i < actions.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(height: AppSpace.sm),
                          actions[i],
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Big friendly heading with a calmer supporting line.
class DsHeading extends StatelessWidget {
  const DsHeading(this.title, {super.key, this.subtitle, this.center = false});

  final String title;
  final String? subtitle;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextAlign align = center ? TextAlign.center : TextAlign.start;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      child: Column(
        crossAxisAlignment:
            center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: align,
              style: AppType.title.copyWith(fontSize: 26),
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Text(
              subtitle!,
              textAlign: align,
              style: AppType.body.copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum DsTone { error, success, info }

/// Inline message with an icon AND words, so status never relies on colour.
/// Announced to screen readers when it appears.
class DsMessage extends StatelessWidget {
  const DsMessage(this.text, {super.key, this.tone = DsTone.error});

  final String text;
  final DsTone tone;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final (IconData icon, Color color, String prefix) = switch (tone) {
      DsTone.error => (Icons.error_outline, AppColors.sosRed, 'Error'),
      DsTone.success => (Icons.check_circle_outline, brand.accentInk, 'Done'),
      DsTone.info => (Icons.info_outline, Theme.of(context).colorScheme.secondary, 'Note'),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      label: '$prefix: $text',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpace.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: color, size: 20),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  text,
                  style: AppType.secondary.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tappable card option (create / join, etc.). Minimum 72dp, wraps at large
/// text, and is one semantic button.
class DsOptionCard extends StatelessWidget {
  const DsOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: brand.sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              children: <Widget>[
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: brand.accent,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(icon, color: brand.onAccent, size: 26),
                ),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: AppType.headline),
                      const SizedBox(height: AppSpace.xxs),
                      Text(
                        subtitle,
                        style: AppType.secondary
                            .copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Primary action that shows progress while [busy]. Use inside
/// [DsPage.actions].
class DsBusyButton extends StatelessWidget {
  const DsBusyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.style = DsPillStyle.filled,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final DsPillStyle style;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (!busy) {
      return DsPillButton(
        label: label,
        onPressed: onPressed,
        style: style,
        icon: icon,
      );
    }
    return Semantics(
      label: 'Working',
      liveRegion: true,
      child: DsPillButton(
        label: 'Please wait',
        onPressed: null,
        style: style,
        icon: Icons.hourglass_top,
      ),
    );
  }
}

/// Shimmer-free skeleton block. Static when the OS asks for reduced motion.
class DsSkeleton extends StatefulWidget {
  const DsSkeleton({super.key, this.width, this.height = 16, this.radius});

  final double? width;
  final double height;
  final double? radius;

  @override
  State<DsSkeleton> createState() => _DsSkeletonState();
}

class _DsSkeletonState extends State<DsSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _c.stop();
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color base = Theme.of(context).colorScheme.onSurface;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? _) => Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: base.withValues(alpha: 0.06 + 0.06 * _c.value),
            borderRadius: BorderRadius.circular(widget.radius ?? AppRadius.sm),
          ),
        ),
      ),
    );
  }
}

/// A column of skeleton list rows; announces "Loading" once.
class DsSkeletonList extends StatelessWidget {
  const DsSkeletonList({super.key, this.rows = 4, this.avatar = true});

  final int rows;
  final bool avatar;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xl,
          vertical: AppSpace.md,
        ),
        child: Column(
          children: <Widget>[
            for (int i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
                child: Row(
                  children: <Widget>[
                    if (avatar) ...<Widget>[
                      const DsSkeleton(width: 40, height: 40, radius: 20),
                      const SizedBox(width: AppSpace.md),
                    ],
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          DsSkeleton(width: 160, height: 14),
                          SizedBox(height: AppSpace.sm),
                          DsSkeleton(width: 100, height: 11),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
