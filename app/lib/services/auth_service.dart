import 'api_client.dart';
import 'background_location_service.dart';
import 'biometric_service.dart';
import 'token_storage.dart';

/// Thrown when the backend requires a TOTP code (2FA) to complete login.
///
/// The backend returns 401 "invalid totp code" when TOTP is enabled and the
/// code is missing or wrong; [AuthService.login] translates that into this
/// exception so callers can prompt for a code distinctly from other failures.
class TotpRequiredException implements Exception {
  const TotpRequiredException([this.message = 'Enter your 2FA code.']);

  final String message;

  @override
  String toString() => 'TotpRequiredException: $message';
}

/// Thrown when sign-up created the account but the follow-up login could not
/// establish a session (so the user has an account but no tokens).
class AccountCreatedException implements Exception {
  const AccountCreatedException([this.message = neutralMessage]);

  /// Deliberately neutral: the server returns the same 201 for a new and an
  /// already-registered email, so the app must not say which happened.
  static const String neutralMessage =
      'Check your details. If you already have an account, try signing in.';

  final String message;

  @override
  String toString() => 'AccountCreatedException: $message';
}

/// Handles sign-up and login against the real backend, persisting tokens via
/// [TokenStorage] (flutter_secure_storage → iOS Keychain / Android Keystore).
class AuthService {
  AuthService._();

  /// Registers a new account and immediately logs in to obtain a token pair.
  ///
  /// The register endpoint returns the user but no tokens, so we follow it
  /// with a login. If that login fails we retry once; if it still fails the
  /// account exists without a session, so we throw [AccountCreatedException]
  /// (rather than leaving the user to re-submit sign-up and hit a 409).
  ///
  /// [inviteCode], when provided, is validated by the server and assigns the
  /// new user to the code's family and role. On a managed server it is required.
  static Future<void> signUp({
    required String email,
    required String password,
    required String name,
    String? inviteCode,
  }) async {
    await ApiClient.register(
      email: email,
      password: password,
      name: name,
      inviteCode: inviteCode,
    );
    try {
      await _loginAndPersist(email: email, password: password);
    } catch (_) {
      // Register succeeded but the follow-up login failed. Retry once to
      // tolerate a transient failure; if it still fails, surface a distinct
      // "account created, please log in" state.
      try {
        await _loginAndPersist(email: email, password: password);
      } catch (_) {
        throw const AccountCreatedException();
      }
    }
  }

  /// Logs in with an email + password (and optional TOTP code), persisting the
  /// returned token pair.
  ///
  /// [identifier] is the email address. Throws [TotpRequiredException] when the
  /// backend reports that a TOTP code is required (or the supplied code is
  /// wrong).
  static Future<void> login({
    required String identifier,
    required String password,
    String? totpCode,
  }) async {
    try {
      await _loginAndPersist(
        email: identifier,
        password: password,
        totpCode: totpCode,
      );
    } on ApiException catch (e) {
      if (e.status == 401 && _isTotpRequired(e.message)) {
        throw const TotpRequiredException();
      }
      rethrow;
    }
  }

  /// Clears stored tokens and the device id to log the user out.
  static Future<void> logout({bool notifyServer = true}) async {
    // Ask the server to kill outstanding JWTs when the route exists. A missing
    // endpoint (older server) must not block local sign-out. Skip after
    // account deletion — the user row is already gone.
    if (notifyServer) {
      try {
        await ApiClient.logout();
      } catch (_) {}
    }
    // Stop background reporting before clearing credentials, so the background
    // isolate never reports with a dead session.
    await BackgroundLocationService.stop();
    await TokenStorage.clear();
  }

  static Future<void> _loginAndPersist({
    required String email,
    required String password,
    String? totpCode,
  }) async {
    final Map<String, dynamic> tokens = await ApiClient.login(
      email: email,
      password: password,
      totpCode: totpCode,
    );
    // Biometric opt-in belongs to the previous session/account. Refuse to save
    // a fresh token pair until the flag is reset, so a failed preference clear
    // can never silently carry biometric state across users.
    final bool biometricReset =
        await BiometricService.instance.setEnabled(false);
    if (!biometricReset) {
      throw StateError('Could not initialize local session security.');
    }
    await TokenStorage.saveTokens(
      access: tokens['access_token'] as String,
      refresh: tokens['refresh_token'] as String,
    );
    // A fresh session is now active: re-arm the session-expired redirect so a
    // later expiry fires it again.
    ApiClient.markSessionActive();
    // Background location reporting is started by MapScreen once it is shown
    // (and the app is in the foreground), not here.
  }

  /// Whether a 401 message indicates TOTP is required (rather than bad
  /// credentials). Matches the backend's stable tokens.
  static bool _isTotpRequired(String message) {
    final String m = message.toLowerCase();
    return m.contains('totp') || m.contains('two-factor') || m.contains('2fa');
  }
}
