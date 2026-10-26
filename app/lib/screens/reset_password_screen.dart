import 'package:flutter/material.dart';

import '../services/security_api.dart';
import '../services/security_format.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// "Have a reset code?" flow from the login screen: email + admin-issued code
/// + new password. Every failure from the server is intentionally generic.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    this.initialEmail = '',
    this.api = const ApiSecurityApi(),
  });

  final String initialEmail;
  final SecurityApi api;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);
  final TextEditingController _code = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_email.text.trim().isEmpty || _code.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email and the reset code.');
      return;
    }
    final String? bad = validateNewPassword(_next.text, _confirm.text);
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.resetPasswordWithCode(
        email: _email.text.trim(),
        code: _code.text.trim().toUpperCase(),
        newPassword: _next.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return SecurityPage(
        title: 'Reset password',
        children: <Widget>[
          const SizedBox(height: AppSpace.xxl),
          Center(
            child: DsListRow.iconTile(context, Icons.check_circle_outline),
          ),
          const SizedBox(height: AppSpace.lg),
          const DsHeading(
            'Password updated',
            subtitle:
                'All devices were signed out. Sign in with your new password.',
            center: true,
          ),
          BusyButton(
            label: 'Back to sign in',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    }
    return SecurityPage(
      title: 'Reset password',
      children: <Widget>[
        const DsHeading(
          'Use a reset code',
          subtitle: 'A family admin can give you a one-time reset code. It '
              'works once and expires after 30 minutes.',
        ),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _code,
          enabled: !_busy,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Reset code',
            helperText: 'Looks like ABCDE-FGHJK',
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        SecurePasswordField(
          controller: _next,
          label: 'New password',
          enabled: !_busy,
        ),
        const SizedBox(height: AppSpace.lg),
        SecurePasswordField(
          controller: _confirm,
          label: 'Confirm new password',
          enabled: !_busy,
          onSubmitted: _submit,
        ),
        if (_error != null) ErrorText(_error!),
        const SizedBox(height: AppSpace.xl),
        BusyButton(label: 'Reset password', onPressed: _submit, busy: _busy),
      ],
    );
  }
}
