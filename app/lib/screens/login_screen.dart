import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';
import '../services/push_service.dart';
import '../theme/app_theme.dart';
import '../widgets/openfamily_brand.dart';
import 'map_screen.dart';
import 'reset_password_screen.dart';
import 'sign_up_screen.dart';

/// Log In for existing users. Accepts an email address OR phone number plus
/// a password, persists tokens via [AuthService] (flutter_secure_storage),
/// and navigates to the map.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _totpCode = TextEditingController();
  bool _obscure = true;
  bool _totpRequired = false;
  bool _useRecovery = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    _totpCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_identifier.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    if (_totpRequired && _totpCode.text.trim().isEmpty) {
      setState(() => _error = _useRecovery
          ? 'Enter one of your recovery codes.'
          : 'Enter your two-factor code.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AuthService.login(
        identifier: _identifier.text.trim(),
        password: _password.text,
        totpCode: _totpRequired ? _totpCode.text.trim().replaceAll(' ', '') : null,
      );
    } on TotpRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _totpRequired = true;
        _error = e.message;
      });
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
      return;
    } on SessionExpiredException {
      // The app root already redirected to login; abort our own navigation.
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
    // Clear the whole stack (including the welcome screen underneath) so the
    // Android back button on the map exits the app instead of revealing the
    // logged-out welcome screen.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const MapScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log In')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: OpenFamilyMark(size: 72)),
                  const SizedBox(height: 16),
                  Text(
                    'Welcome back',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _identifier,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    onChanged: (_) {
                      // A different account may not need 2FA; reset the flag
                      // and any stale code/error from the previous attempt.
                      if (_totpRequired) {
                        setState(() {
                          _totpRequired = false;
                          _totpCode.clear();
                          _useRecovery = false;
                          _error = null;
                        });
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (_totpRequired) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _totpCode,
                      keyboardType: _useRecovery
                          ? TextInputType.text
                          : TextInputType.number,
                      textCapitalization: TextCapitalization.characters,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const <String>[AutofillHints.oneTimeCode],
                      decoration: InputDecoration(
                        labelText:
                            _useRecovery ? 'Recovery code' : 'Two-factor code',
                        hintText:
                            _useRecovery ? 'ABCDE-FGHJK' : '6-digit code',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _submitting
                            ? null
                            : () => setState(() {
                                  _useRecovery = !_useRecovery;
                                  _totpCode.clear();
                                  _error = null;
                                }),
                        child: Text(
                          _useRecovery
                              ? 'Use an authenticator code instead'
                              : 'Lost your device? Use a recovery code',
                        ),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: AppColors.statusRed,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Log In'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ResetPasswordScreen(
                            initialEmail: _identifier.text.trim(),
                          ),
                        ),
                      ),
                      child: const Text('Have a reset code?'),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Don't have an account?",
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SignUpScreen(),
                          ),
                        ),
                        child: const Text('Sign up'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
