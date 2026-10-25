import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import '../theme/app_theme.dart';
import 'security_widgets.dart';
import 'welcome_screen.dart';

/// Permanent account deletion with step-up (password, plus a code when
/// two-factor is on) and an explicit irreversible confirmation.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({
    super.key,
    required this.totpEnabled,
    this.api = const ApiSecurityApi(),
    this.onDeleted,
  });

  final bool totpEnabled;
  final SecurityApi api;

  /// Called after a successful delete. Defaults to clearing local state and
  /// returning to the welcome screen.
  final Future<void> Function(BuildContext context)? onDeleted;

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  bool _understood = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    if (widget.totpEnabled && _code.text.trim().isEmpty) {
      setState(() => _error = 'Enter a code from your authenticator app.');
      return;
    }
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Delete forever?'),
        content: const Text('This cannot be undone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sosRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Delete my account'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.deleteAccount(
        password: _password.text,
        totpCode: widget.totpEnabled ? normalizeCode(_code.text) : null,
      );
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.status == 409
            ? '${e.message}. Promote another admin first, or remove the '
                'other members.'
            : errorText(e);
      });
      return;
    }
    if (!mounted) return;
    if (widget.onDeleted != null) {
      await widget.onDeleted!(context);
      if (mounted) setState(() => _busy = false);
      return;
    }
    await AuthService.logout(notifyServer: false);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SecurityPage(
      title: 'Delete account',
      children: <Widget>[
        const Callout(
          icon: Icons.delete_forever,
          danger: true,
          text: 'Deleting your account is permanent and cannot be undone.',
        ),
        const SizedBox(height: 16),
        Text('What gets deleted', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          '• Your profile, photo and sign-in details\n'
          '• Your devices and every stored location point\n'
          '• Your emergency contacts and active sessions\n'
          '• Your family too, if you are its only member',
        ),
        const SizedBox(height: 12),
        const Text(
          'If you are the last admin of a family that still has other '
          'people, promote someone else first. Want a copy of your data? '
          'Download it from Security before deleting.',
        ),
        const SizedBox(height: 20),
        SecurePasswordField(
          controller: _password,
          label: 'Password',
          enabled: !_busy,
        ),
        if (widget.totpEnabled) ...<Widget>[
          const SizedBox(height: 16),
          CodeField(controller: _code, enabled: !_busy),
        ],
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _understood,
          onChanged: _busy ? null : (bool? v) => setState(() => _understood = v ?? false),
          title: const Text('I understand this is permanent'),
        ),
        if (_error != null) ErrorText(_error!),
        const SizedBox(height: 12),
        BusyButton(
          label: 'Delete my account',
          danger: true,
          busy: _busy,
          onPressed: _understood ? _submit : null,
        ),
      ],
    );
  }
}
