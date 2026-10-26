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

/// Primary action button: 48dp+ tall, shows progress while busy.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(kMinTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xl,
          vertical: AppSpace.md,
        ),
        backgroundColor: danger ? AppColors.sosRed : null,
        foregroundColor: danger ? Colors.white : null,
        textStyle: AppType.body.copyWith(fontWeight: FontWeight.w700),
      ),
      onPressed: busy ? null : onPressed,
      child: busy
          ? Semantics(
              label: 'Working',
              liveRegion: true,
              child: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Text(label, textAlign: TextAlign.center),
    );
  }
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
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).sheet,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
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

/// Callout box for warnings / explanations.
class Callout extends StatelessWidget {
  const Callout({super.key, required this.icon, required this.text, this.danger = false});
  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color tint = danger ? AppColors.sosRed : AppColors.statusOrange;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        border: Border.all(color: tint.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: tint, semanticLabel: danger ? 'Warning' : 'Note'),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AppType.secondary.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ))),
        ],
      ),
    );
  }
}

/// Standard scrolling page body for security forms.
class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(AppSpace.xxl),
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// Convenience: message for any thrown error.
String errorText(Object e) => securityErrorMessage(e);
