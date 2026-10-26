import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/security_format.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Shared building blocks for the Security screens.

/// Password input with a 48dp show/hide toggle.
class SecurePasswordField extends StatefulWidget {
  const SecurePasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.autofillHints,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final VoidCallback? onSubmitted;

  @override
  State<SecurePasswordField> createState() => _SecurePasswordFieldState();
}

class _SecurePasswordFieldState extends State<SecurePasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscure,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          tooltip: _obscure ? 'Show password' : 'Hide password',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}

/// Field for a 6-digit authenticator code or a recovery code.
class CodeField extends StatelessWidget {
  const CodeField({
    super.key,
    required this.controller,
    this.label = 'Authenticator or recovery code',
    this.enabled = true,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      autofillHints: const <String>[AutofillHints.oneTimeCode],
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      decoration: InputDecoration(
        labelText: label,
        helperText: '6-digit code, or a recovery code like ABCDE-FGHJK',
        prefixIcon: const Icon(Icons.pin_outlined),
      ),
    );
  }
}

/// Inline error message (icon + words), announced to screen readers.
class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => DsMessage(message);
}

/// Primary action button: 48dp+ tall, shows progress while busy. Renders
/// with the design system's pill; [danger] uses the system's destructive
/// style.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.danger = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool danger;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => DsBusyButton(
        label: label,
        onPressed: onPressed,
        busy: busy,
        icon: icon,
        style: danger ? DsPillStyle.danger : DsPillStyle.filled,
      );
}

/// Full-area loading / error (with Retry) state.
class LoadStateView extends StatelessWidget {
  const LoadStateView({super.key, this.error, this.offline = false, this.onRetry});

  /// Null means "loading".
  final String? error;
  final bool offline;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return const Align(
        alignment: Alignment.topCenter,
        child: DsSkeletonList(rows: 4, avatar: false),
      );
    }
    return DsErrorState(
      icon: offline ? Icons.cloud_off : Icons.error_outline,
      title: offline ? 'No connection' : 'Something went wrong',
      message: error!,
      onRetry: onRetry,
    );
  }
}

/// A selectable monospace value with a 48dp copy button.
class CopyableValue extends StatelessWidget {
  const CopyableValue({
    super.key,
    required this.value,
    required this.label,
    this.display,
  });

  final String value;
  final String label;
  final String? display;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: label,
      child: Container(
        padding: const EdgeInsets.only(left: AppSpace.md),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).sheet,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
                child: SelectableText(
                  display ?? value,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy $label',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$label copied')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Callout box for warnings / explanations. Always icon AND words; [danger]
/// uses the system's destructive red, otherwise the calm warning orange.
class Callout extends StatelessWidget {
  const Callout({super.key, required this.icon, required this.text, this.danger = false});
  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color tint = danger ? AppColors.sosRed : AppColors.statusOrange;
    return Semantics(
      container: true,
      label: '${danger ? 'Warning' : 'Note'}: $text',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          border: Border.all(color: tint.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: tint),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                text,
                style: AppType.secondary.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standard page for security forms: a [DsPage] with an optional heading and
/// pinned [actions] (which scroll with the content at large text).
class SecurityPage extends StatelessWidget {
  const SecurityPage({
    super.key,
    required this.title,
    required this.children,
    this.heading,
    this.subtitle,
    this.actions = const <Widget>[],
    this.step,
    this.totalSteps,
    this.appBarActions,
  });

  final String title;
  final List<Widget> children;
  final int? step;
  final int? totalSteps;
  final List<Widget>? appBarActions;

  /// Big heading above [children]; [subtitle] is the calm supporting line.
  final String? heading;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: title,
      actions: actions,
      step: step,
      totalSteps: totalSteps,
      appBarActions: appBarActions,
      children: <Widget>[
        if (heading != null) DsHeading(heading!, subtitle: subtitle),
        ...children,
      ],
    );
  }
}

/// Convenience: message for any thrown error.
String errorText(Object e) => securityErrorMessage(e);
