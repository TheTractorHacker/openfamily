import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';
import '../services/push_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'login_screen.dart';
import 'permissions_screen.dart';

/// A practical email format check (not RFC-exhaustive).
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Sign-up: name, email, password, and an invite code. Kept minimal on purpose —
/// the invite code is the security gate on a managed server, and everything else
/// (profile photo, etc.) can be added later in Settings.
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _inviteCode = TextEditingController();
  bool _obscure = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String name = _name.text.trim();
    final String email = _email.text.trim();
    final String password = _password.text;
    final String inviteCode = _inviteCode.text.trim();

    if (name.isEmpty) {
      setState(() => _error = 'Enter your name.');
      return;
    }
    if (!_emailPattern.hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AuthService.signUp(
        name: name,
        email: email,
        password: password,
        inviteCode: inviteCode.isEmpty ? null : inviteCode,
      );
    } on AccountCreatedException catch (e) {
      // We couldn't establish a session. The server answers a duplicate email
      // with the same 201 as a new account, so this may mean the account
      // already existed. Never claim either way; just point to sign-in.
      if (!mounted) return;
      _redirectToLogin(e.message);
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 409) {
        // Older servers answer a duplicate with 409. Stay neutral either way.
        _redirectToLogin(AccountCreatedException.neutralMessage);
        return;
      }
      setState(() {
        _submitting = false;
        _error = e.message;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Something went wrong. Please try again.';
      });
      return;
    }

    // Auth succeeded; register the device (best-effort, non-blocking).
    try {
      await DeviceService.ensureRegistered();
      await PushService.sync();
    } on SessionExpiredException {
      // Session expired during device registration; the app root already
      // redirected to login. Abort navigation so we don't land on a protected
      // screen with cleared tokens.
      return;
    } catch (_) {
      // Non-fatal: device registration can be retried later.
    }

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PermissionsScreen()),
    );
  }

  /// Shows [message] and redirects to the login screen (replacing this one).
  void _redirectToLogin(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    // Clear the stack so only one LoginScreen is ever on it (a plain
    // pushReplacement could stack duplicates when the sign-up screen was
    // itself pushed on top of an existing LoginScreen).
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'Create account',
      step: 1,
      totalSteps: 6,
      actions: <Widget>[
        DsBusyButton(label: 'Continue', busy: _submitting, onPressed: _submit),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
                'Already have an account?',
                style: AppType.secondary.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      ],
      children: <Widget>[
        const DsHeading(
          'Let\'s get you set up',
          subtitle: 'Your email is used to sign you in. Your data stays on '
              'your own server, not ours, not anyone\'s.',
        ),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          autofillHints: const <String>[AutofillHints.name],
          decoration: const InputDecoration(
            labelText: 'Your name',
            hintText: 'Alex Rivera',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const <String>[AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Email address',
            prefixIcon: Icon(Icons.mail_outline),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _password,
          obscureText: _obscure,
          autofillHints: const <String>[AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: 'At least 8 characters',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              constraints: const BoxConstraints(
                minWidth: kMinTarget,
                minHeight: kMinTarget,
              ),
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _inviteCode,
          keyboardType: TextInputType.text,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Invite code',
            hintText: 'e.g. AB12CD34',
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }
}
