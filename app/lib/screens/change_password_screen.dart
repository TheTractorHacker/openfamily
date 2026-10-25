import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import 'security_widgets.dart';

/// Change password. Requires the current password, plus a code when
/// two-factor is on. Other devices are signed out; this one stays signed in.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    super.key,
    required this.totpEnabled,
    this.api = const ApiSecurityApi(),
  });

  final bool totpEnabled;
  final SecurityApi api;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_current.text.isEmpty) {
      setState(() => _error = 'Enter your current password.');
      return;
    }
    final String? bad = validateNewPassword(_next.text, _confirm.text);
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    if (widget.totpEnabled && _code.text.trim().isEmpty) {
      setState(() => _error = 'Enter a code from your authenticator app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
        totpCode: widget.totpEnabled ? normalizeCode(_code.text) : null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password changed. Other devices were signed out.'),
        ),
      );
      Navigator.of(context).pop(true);
    } on SessionExpiredException {
      return;
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
    return SecurityPage(
      title: 'Change password',
      children: <Widget>[
        SecurePasswordField(
          controller: _current,
          label: 'Current password',
          enabled: !_busy,
        ),
        const SizedBox(height: 16),
        SecurePasswordField(
          controller: _next,
          label: 'New password',
          enabled: !_busy,
        ),
        const SizedBox(height: 16),
        SecurePasswordField(
          controller: _confirm,
          label: 'Confirm new password',
          enabled: !_busy,
          onSubmitted: widget.totpEnabled ? null : _submit,
        ),
        if (widget.totpEnabled) ...<Widget>[
          const SizedBox(height: 16),
          CodeField(controller: _code, enabled: !_busy, onSubmitted: _submit),
        ],
        if (_error != null) ErrorText(_error!),
        const SizedBox(height: 20),
        BusyButton(label: 'Change password', onPressed: _submit, busy: _busy),
      ],
    );
  }
}
