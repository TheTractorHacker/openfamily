import 'package:flutter/services.dart';
import 'package:local_auth/error_codes.dart' as local_auth_error;
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device's readiness for biometric-only authentication.
enum BiometricAvailabilityStatus {
  available,
  unsupported,
  notEnrolled,
  unavailable,
}

/// Stable error codes that the UI can handle without depending on platform
/// exception strings from `local_auth`.
enum BiometricErrorCode {
  disabled,
  unsupported,
  notEnrolled,
  authenticationFailed,
  temporarilyLockedOut,
  permanentlyLockedOut,
  passcodeNotSet,
  storageUnavailable,
  unavailable,
}

/// A user-presentable biometric error, with an optional platform code for
/// diagnostics.
class BiometricError {
  const BiometricError({
    required this.code,
    required this.message,
    this.platformCode,
  });

  final BiometricErrorCode code;
  final String message;
  final String? platformCode;
}

/// Result of checking biometric hardware and enrollment.
class BiometricAvailability {
  BiometricAvailability._({
    required this.status,
    required this.isDeviceSupported,
    required this.canCheckBiometrics,
    List<BiometricType> enrolledBiometrics = const <BiometricType>[],
    this.error,
  }) : enrolledBiometrics =
            List<BiometricType>.unmodifiable(enrolledBiometrics);

  factory BiometricAvailability.available({
    required bool isDeviceSupported,
    required List<BiometricType> enrolledBiometrics,
  }) {
    return BiometricAvailability._(
      status: BiometricAvailabilityStatus.available,
      isDeviceSupported: isDeviceSupported,
      canCheckBiometrics: true,
      enrolledBiometrics: enrolledBiometrics,
    );
  }

  factory BiometricAvailability.unsupported({
    required bool isDeviceSupported,
  }) {
    return BiometricAvailability._(
      status: BiometricAvailabilityStatus.unsupported,
      isDeviceSupported: isDeviceSupported,
      canCheckBiometrics: false,
      error: const BiometricError(
        code: BiometricErrorCode.unsupported,
        message: 'Biometric authentication is not supported on this device.',
      ),
    );
  }

  factory BiometricAvailability.notEnrolled({
    required bool isDeviceSupported,
  }) {
    return BiometricAvailability._(
      status: BiometricAvailabilityStatus.notEnrolled,
      isDeviceSupported: isDeviceSupported,
      canCheckBiometrics: true,
      error: const BiometricError(
        code: BiometricErrorCode.notEnrolled,
        message: 'Set up face or fingerprint recognition in device settings '
            'before enabling biometric unlock.',
      ),
    );
  }

  factory BiometricAvailability.unavailable(BiometricError error) {
    return BiometricAvailability._(
      status: BiometricAvailabilityStatus.unavailable,
      isDeviceSupported: false,
      canCheckBiometrics: false,
      error: error,
    );
  }

  final BiometricAvailabilityStatus status;
  final bool isDeviceSupported;
  final bool canCheckBiometrics;
  final List<BiometricType> enrolledBiometrics;
  final BiometricError? error;

  bool get isAvailable => status == BiometricAvailabilityStatus.available;

  String get message =>
      error?.message ?? 'Biometric authentication is ready to use.';
}

/// Result returned by [BiometricService.authenticate].
class BiometricAuthenticationResult {
  const BiometricAuthenticationResult.success()
      : authenticated = true,
        error = null;

  const BiometricAuthenticationResult.failure(BiometricError failure)
      : authenticated = false,
        error = failure;

  final bool authenticated;
  final BiometricError? error;
}

/// Injectable subset of `local_auth` used by [BiometricService].
abstract interface class BiometricAuthenticator {
  Future<bool> get canCheckBiometrics;

  Future<bool> isDeviceSupported();

  Future<List<BiometricType>> getAvailableBiometrics();

  Future<bool> authenticate({
    required String localizedReason,
    required AuthenticationOptions options,
  });

  Future<bool> stopAuthentication();
}

/// Production adapter for `local_auth` 2.3.x.
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? localAuthentication})
      : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> get canCheckBiometrics =>
      _localAuthentication.canCheckBiometrics;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() =>
      _localAuthentication.getAvailableBiometrics();

  @override
  Future<bool> isDeviceSupported() => _localAuthentication.isDeviceSupported();

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required AuthenticationOptions options,
  }) {
    return _localAuthentication.authenticate(
      localizedReason: localizedReason,
      options: options,
    );
  }

  @override
  Future<bool> stopAuthentication() =>
      _localAuthentication.stopAuthentication();
}

/// Injectable persistence used by [BiometricService].
abstract interface class BiometricPreferenceStore {
  Future<bool> isEnabled();

  Future<bool> setEnabled(bool enabled);
}

/// Stores only the user's opt-in flag. No biometric data leaves the OS.
class SharedPreferencesBiometricPreferenceStore
    implements BiometricPreferenceStore {
  static const String enabledKey = 'biometric_auth_enabled';

  @override
  Future<bool> isEnabled() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return preferences.getBool(enabledKey) ?? false;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return preferences.setBool(enabledKey, enabled);
  }
}

/// Injectable persistence for the app-lock grace period.
///
/// The grace period is how long the app may sit backgrounded before the
/// biometric lock takes over. Zero (the default, and the historical behavior)
/// means locking on every backgrounding — including transient ones like
/// pulling down the notification shade.
abstract interface class LockGraceStore {
  Future<Duration> readGrace();

  Future<bool> writeGrace(Duration grace);
}

/// SharedPreferences-backed [LockGraceStore].
class SharedPreferencesLockGraceStore implements LockGraceStore {
  static const String graceSecondsKey = 'app_lock_grace_seconds';

  @override
  Future<Duration> readGrace() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return Duration(seconds: preferences.getInt(graceSecondsKey) ?? 0);
  }

  @override
  Future<bool> writeGrace(Duration grace) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return preferences.setInt(graceSecondsKey, grace.inSeconds);
  }
}

/// Coordinates biometric availability, opt-in persistence, and authentication.
class BiometricService {
  static final BiometricService instance = BiometricService();

  BiometricService({
    BiometricAuthenticator? authenticator,
    BiometricPreferenceStore? preferenceStore,
    LockGraceStore? graceStore,
  })  : _authenticator = authenticator ?? LocalAuthBiometricAuthenticator(),
        _preferenceStore =
            preferenceStore ?? SharedPreferencesBiometricPreferenceStore(),
        _graceStore = graceStore ?? SharedPreferencesLockGraceStore();

  static const String defaultReason =
      'Use your biometric to unlock Orbitly.';

  final BiometricAuthenticator _authenticator;
  final BiometricPreferenceStore _preferenceStore;
  final LockGraceStore _graceStore;
  int _activeAuthentications = 0;

  /// The longest accepted lock grace period; longer stored values (corrupt or
  /// tampered preferences) fall back to immediate locking.
  static const Duration maxLockGrace = Duration(minutes: 15);

  /// Whether this service is currently waiting on a native biometric prompt.
  ///
  /// Lifecycle observers can use this to avoid starting a second prompt when
  /// the first prompt itself causes the app to pause and resume.
  bool get isAuthenticating => _activeAuthentications > 0;

  /// Returns whether the user opted in.
  ///
  /// Read failures deliberately propagate so the root UI gate can fail closed;
  /// treating an unavailable preference store as "disabled" could expose an
  /// otherwise protected session.
  Future<bool> isEnabled() => _preferenceStore.isEnabled();

  /// Persists the user's opt-in and reports whether the write succeeded.
  Future<bool> setEnabled(bool enabled) async {
    try {
      return await _preferenceStore.setEnabled(enabled);
    } catch (_) {
      return false;
    }
  }

  /// The user-chosen app-lock grace period (zero = lock immediately).
  ///
  /// Read failures are fail-closed: an unreadable preference means immediate
  /// locking, never a silently weaker lock.
  Future<Duration> lockGrace() async {
    try {
      final Duration grace = await _graceStore.readGrace();
      if (grace.isNegative || grace > maxLockGrace) return Duration.zero;
      return grace;
    } catch (_) {
      return Duration.zero;
    }
  }

  /// Persists the lock grace period, clamped to [maxLockGrace].
  Future<bool> setLockGrace(Duration grace) {
    final Duration clamped =
        grace.isNegative || grace > maxLockGrace ? Duration.zero : grace;
    try {
      return _graceStore.writeGrace(clamped);
    } catch (_) {
      return Future<bool>.value(false);
    }
  }

  /// Distinguishes unsupported hardware from missing biometric enrollment.
  Future<BiometricAvailability> getAvailability() async {
    try {
      final bool deviceSupported = await _authenticator.isDeviceSupported();
      final bool canCheck = await _authenticator.canCheckBiometrics;

      // `isDeviceSupported` also includes device PIN/passcode support, while
      // this app intentionally requires biometrics. `canCheckBiometrics` is
      // therefore the deciding capability flag.
      if (!canCheck) {
        return BiometricAvailability.unsupported(
          isDeviceSupported: deviceSupported,
        );
      }

      final List<BiometricType> enrolled =
          await _authenticator.getAvailableBiometrics();
      if (enrolled.isEmpty) {
        return BiometricAvailability.notEnrolled(
          isDeviceSupported: deviceSupported,
        );
      }

      return BiometricAvailability.available(
        isDeviceSupported: deviceSupported,
        enrolledBiometrics: enrolled,
      );
    } on PlatformException catch (exception) {
      return _availabilityForPlatformException(exception);
    } catch (_) {
      return BiometricAvailability.unavailable(
        const BiometricError(
          code: BiometricErrorCode.unavailable,
          message: 'Biometric authentication is unavailable right now. '
              'Please try again.',
        ),
      );
    }
  }

  /// Prompts for biometric-only authentication.
  ///
  /// By default, the persisted opt-in must be enabled. Pass
  /// [requireEnabled] as false when authenticating as part of the opt-in flow,
  /// before saving the setting.
  Future<BiometricAuthenticationResult> authenticate({
    String localizedReason = defaultReason,
    bool requireEnabled = true,
  }) async {
    if (localizedReason.trim().isEmpty) {
      return const BiometricAuthenticationResult.failure(
        BiometricError(
          code: BiometricErrorCode.unavailable,
          message: 'Biometric authentication could not be started.',
        ),
      );
    }

    if (requireEnabled) {
      try {
        if (!await _preferenceStore.isEnabled()) {
          return const BiometricAuthenticationResult.failure(
            BiometricError(
              code: BiometricErrorCode.disabled,
              message: 'Biometric unlock is turned off in app settings.',
            ),
          );
        }
      } catch (_) {
        return const BiometricAuthenticationResult.failure(
          BiometricError(
            code: BiometricErrorCode.storageUnavailable,
            message: 'Biometric settings could not be read. Please try again.',
          ),
        );
      }
    }

    final BiometricAvailability availability = await getAvailability();
    if (!availability.isAvailable) {
      return BiometricAuthenticationResult.failure(
        availability.error ??
            const BiometricError(
              code: BiometricErrorCode.unavailable,
              message: 'Biometric authentication is unavailable right now.',
            ),
      );
    }

    _activeAuthentications++;
    try {
      final bool authenticated = await _authenticator.authenticate(
        localizedReason: localizedReason.trim(),
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          sensitiveTransaction: true,
          useErrorDialogs: false,
        ),
      );

      if (authenticated) {
        return const BiometricAuthenticationResult.success();
      }
      return const BiometricAuthenticationResult.failure(
        BiometricError(
          code: BiometricErrorCode.authenticationFailed,
          message: 'Biometric authentication was not completed. '
              'Please try again.',
        ),
      );
    } on PlatformException catch (exception) {
      return BiometricAuthenticationResult.failure(
        _errorForPlatformException(exception),
      );
    } catch (_) {
      return const BiometricAuthenticationResult.failure(
        BiometricError(
          code: BiometricErrorCode.unavailable,
          message: 'Biometric authentication is unavailable right now. '
              'Please try again.',
        ),
      );
    } finally {
      _activeAuthentications--;
    }
  }

  /// Best-effort cancellation of an active platform authentication prompt.
  Future<bool> cancelAuthentication() async {
    try {
      return await _authenticator.stopAuthentication();
    } catch (_) {
      return false;
    }
  }

  static BiometricAvailability _availabilityForPlatformException(
    PlatformException exception,
  ) {
    final BiometricError error = _errorForPlatformException(exception);
    switch (error.code) {
      case BiometricErrorCode.unsupported:
        return BiometricAvailability.unsupported(isDeviceSupported: false);
      case BiometricErrorCode.notEnrolled:
        return BiometricAvailability.notEnrolled(isDeviceSupported: true);
      default:
        return BiometricAvailability.unavailable(error);
    }
  }

  static BiometricError _errorForPlatformException(
    PlatformException exception,
  ) {
    switch (exception.code) {
      case local_auth_error.notAvailable:
      case local_auth_error.otherOperatingSystem:
      case local_auth_error.biometricOnlyNotSupported:
        return BiometricError(
          code: BiometricErrorCode.unsupported,
          message: 'Biometric authentication is not supported on this device.',
          platformCode: exception.code,
        );
      case local_auth_error.notEnrolled:
        return BiometricError(
          code: BiometricErrorCode.notEnrolled,
          message: 'Set up face or fingerprint recognition in device settings '
              'before enabling biometric unlock.',
          platformCode: exception.code,
        );
      case local_auth_error.lockedOut:
        return BiometricError(
          code: BiometricErrorCode.temporarilyLockedOut,
          message: 'Biometric authentication is temporarily locked after too '
              'many attempts. Please try again later.',
          platformCode: exception.code,
        );
      case local_auth_error.permanentlyLockedOut:
        return BiometricError(
          code: BiometricErrorCode.permanentlyLockedOut,
          message: 'Biometrics are locked. Unlock your device with its '
              'passcode, then try again.',
          platformCode: exception.code,
        );
      case local_auth_error.passcodeNotSet:
        return BiometricError(
          code: BiometricErrorCode.passcodeNotSet,
          message: 'Set up a device passcode before using biometric unlock.',
          platformCode: exception.code,
        );
      default:
        return BiometricError(
          code: BiometricErrorCode.unavailable,
          message: 'Biometric authentication is unavailable right now. '
              'Please try again.',
          platformCode: exception.code,
        );
    }
  }
}
