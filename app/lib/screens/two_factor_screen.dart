import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/security_models.dart';
import '../services/otpauth_launcher.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import 'security_widgets.dart';

enum _Step { password, verify, recovery, disable }

/// Turn two-factor authentication on or off.
///
/// Pops with `true` when the enabled state changed.
class TwoFactorScreen extends StatefulWidget {
  const TwoFactorScreen({
    super.key,
    required this.enabled,
    this.api = const ApiSecurityApi(),
    this.openAuthenticator,
    this.shareText,
  });

  final bool enabled;
  final SecurityApi api;

  /// Overridable for tests. Defaults to the Android intent launcher.
  final Future<bool> Function(String uri)? openAuthenticator;
  final Future<void> Function(String text)? shareText;

  @override
  State<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  late _Step _step = widget.enabled ? _Step.disable : _Step.password;
  TotpSetup? _setup;
  List<String> _recovery = <String>[];
  bool _saved = false;
  bool _busy = false;
  bool _changed = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startSetup() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password to continue.');
      return;
    }
    await _run(() async {
      final TotpSetup s = await widget.api.totpSetup(_password.text);
      if (!mounted) return;
      _password.clear();
      setState(() => _setup = s);
      setState(() => _step = _Step.verify);
    });
  }

  Future<void> _enable() async {
    final String code = normalizeCode(_code.text);
    if (!isTotpShape(code)) {
      setState(() => _error = 'Enter the 6-digit code from your app.');
      return;
    }
    await _run(() async {
      final List<String> codes = await widget.api.totpEnable(code);
      if (!mounted) return;
      _code.clear();
      _changed = true;
      setState(() {
        _recovery = codes;
        _step = _Step.recovery;
      });
    });
  }

  Future<void> _disable() async {
    if (_password.text.isEmpty || _code.text.trim().isEmpty) {
      setState(() => _error = 'Enter your password and a code.');
      return;
    }
    await _run(() async {
      await widget.api.totpDisable(
        password: _password.text,
        code: normalizeCode(_code.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    });
  }

  Future<void> _openApp() async {
    final String uri = _setup?.otpauthUri ?? '';
    final bool ok = await (widget.openAuthenticator ?? OtpauthLauncher.open)(uri);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No authenticator app found. Copy the key instead.'),
        ),
      );
    }
  }

  Future<void> _share() async {
    final String text = 'OpenFamily recovery codes:\n${_recovery.join('\n')}';
    try {
      if (widget.shareText != null) {
        await widget.shareText!(text);
      } else {
        await Share.share(text, subject: 'OpenFamily recovery codes');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the share sheet')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool lockBack = _step == _Step.recovery && !_saved;
    return PopScope(
      canPop: !lockBack,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && lockBack && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Save your recovery codes and tick the box first.'),
            ),
          );
        }
      },
      child: SecurityPage(
        title: 'Two-factor authentication',
        children: <Widget>[
          if (_step == _Step.password) ..._passwordStep(),
          if (_step == _Step.verify) ..._verifyStep(),
          if (_step == _Step.recovery) ..._recoveryStep(),
          if (_step == _Step.disable) ..._disableStep(),
          if (_error != null) ErrorText(_error!),
        ],
      ),
    );
  }

  List<Widget> _passwordStep() => <Widget>[
        Text('Step 1 of 3', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Text(
          'Add a second step when signing in: a 6-digit code from an '
          'authenticator app. Confirm your password to begin.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 20),
        SecurePasswordField(
          controller: _password,
          label: 'Password',
          enabled: !_busy,
          textInputAction: TextInputAction.done,
          onSubmitted: _startSetup,
        ),
        const SizedBox(height: 20),
        BusyButton(label: 'Continue', onPressed: _startSetup, busy: _busy),
      ];

  List<Widget> _verifyStep() {
    final TotpSetup s = _setup!;
    return <Widget>[
      Text('Step 2 of 3', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Text(
        'Add this account to your authenticator app, then enter the 6-digit '
        'code it shows. Two-factor stays off until you confirm.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 16),
      CopyableValue(
        value: s.secret,
        display: formatSecret(s.secret),
        label: 'Setup key',
      ),
      const SizedBox(height: 12),
      if (OtpauthLauncher.isSupported || widget.openAuthenticator != null)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _openApp,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open in authenticator app'),
        ),
      const SizedBox(height: 20),
      CodeField(
        controller: _code,
        label: '6-digit code',
        enabled: !_busy,
        onSubmitted: _enable,
      ),
      const SizedBox(height: 20),
      BusyButton(label: 'Turn on', onPressed: _enable, busy: _busy),
    ];
  }

  List<Widget> _recoveryStep() => <Widget>[
        Text('Step 3 of 3', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        const Callout(
          icon: Icons.warning_amber_rounded,
          text: 'Two-factor is on. These one-time recovery codes are shown '
              'only once. Each works a single time if you lose your '
              'authenticator. Store them somewhere safe.',
        ),
        const SizedBox(height: 16),
        Semantics(
          label: 'Recovery codes',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String c in _recovery)
                Chip(
                  label: SelectableText(
                    c,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        CopyableValue(
          value: _recovery.join('\n'),
          display: 'All ${_recovery.length} codes',
          label: 'Recovery codes',
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _share,
          icon: const Icon(Icons.ios_share),
          label: const Text('Share or save'),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _saved,
          onChanged: (bool? v) => setState(() => _saved = v ?? false),
          title: const Text('I saved these recovery codes'),
        ),
        const SizedBox(height: 8),
        BusyButton(
          label: 'Done',
          onPressed: _saved ? () => Navigator.of(context).pop(_changed) : null,
        ),
      ];

  List<Widget> _disableStep() => <Widget>[
        Text(
          'Two-factor authentication is on. To turn it off, confirm with your '
          'password and a current code or an unused recovery code.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 20),
        SecurePasswordField(
          controller: _password,
          label: 'Password',
          enabled: !_busy,
        ),
        const SizedBox(height: 16),
        CodeField(controller: _code, enabled: !_busy, onSubmitted: _disable),
        const SizedBox(height: 20),
        BusyButton(
          label: 'Turn off two-factor',
          onPressed: _disable,
          busy: _busy,
          danger: true,
        ),
      ];
}
