import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
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
    final bool sure = await showDsConfirm(
      context,
      title: 'Delete forever?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete my account',
      destructive: true,
    );
    if (!sure || !mounted) return;
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SecurityPage(
      title: 'Delete account',
      heading: 'Delete your account',
      subtitle: 'This is permanent. Read what goes with it before you '
          'continue.',
      actions: <Widget>[
        BusyButton(
          label: 'Delete my account',
          icon: Icons.delete_forever,
          danger: true,
          busy: _busy,
          onPressed: _understood ? _submit : null,
        ),
      ],
      children: <Widget>[
        const Callout(
          icon: Icons.delete_forever,
          danger: true,
          text: 'Deleting your account is permanent and cannot be undone.',
        ),
        const SizedBox(height: AppSpace.xl),
        const DsSectionHeader(
          'What gets deleted',
          padding: EdgeInsets.only(bottom: AppSpace.xs),
        ),
        const _Bullet('Your profile, photo and sign-in details'),
        const _Bullet('Your devices and every stored location point'),
        const _Bullet('Your emergency contacts and active sessions'),
        const _Bullet('Your family too, if you are its only member'),
        const SizedBox(height: AppSpace.md),
        Text(
          'If you are the last admin of a family that still has other '
          'people, promote someone else first. Want a copy of your data? '
          'Download it from Security before deleting.',
          style: AppType.secondary.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        SecurePasswordField(
          controller: _password,
          label: 'Password',
          enabled: !_busy,
        ),
        if (widget.totpEnabled) ...<Widget>[
          const SizedBox(height: AppSpace.lg),
          CodeField(controller: _code, enabled: !_busy),
        ],
        const SizedBox(height: AppSpace.sm),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _understood,
          onChanged: _busy
              ? null
              : (bool? v) => setState(() => _understood = v ?? false),
          title: const Text('I understand this is permanent'),
        ),
        if (_error != null) ErrorText(_error!),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.xs),
            child: Icon(Icons.close_rounded, size: 16),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: Text(text, style: AppType.body)),
        ],
      ),
    );
  }
}
