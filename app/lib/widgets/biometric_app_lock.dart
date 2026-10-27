import 'dart:async';

import 'package:flutter/material.dart';

import '../services/biometric_service.dart';
import '../services/token_storage.dart';
import '../theme/app_theme.dart';
import 'openfamily_brand.dart';

/// Places an opaque biometric lock above the entire navigator.
///
/// Keeping this at the [MaterialApp.builder] level protects every authenticated
/// route, including settings and modal screens. It also covers the UI as soon
/// as the app leaves the foreground so the family map is not exposed in the
/// operating system's app-switcher snapshot.
class BiometricAppLock extends StatefulWidget {
  const BiometricAppLock({
    required this.child,
    required this.onLogout,
    this.service,
    this.hasStoredSession,
    super.key,
  });

  final Widget child;
  final Future<void> Function() onLogout;
  final BiometricService? service;
  final Future<bool> Function()? hasStoredSession;

  @override
  State<BiometricAppLock> createState() => _BiometricAppLockState();
}

class _BiometricAppLockState extends State<BiometricAppLock>
    with WidgetsBindingObserver {
  late final BiometricService _service =
      widget.service ?? BiometricService.instance;

  // Start covered so an enabled lock can never flash the protected navigator
  // while its persisted preference and session are being resolved.
  bool _covered = true;
  bool _checking = true;
  bool _authenticating = false;
  bool _loggingOut = false;
  bool _rootAuthenticationBackgrounded = false;
  bool _successfulAuthenticationPendingResume = false;
  bool _externalAuthenticationBackgrounded = false;
  bool _waitingForExternalAuthentication = false;
  String? _error;
  int _evaluationId = 0;

  /// Pending lock application during the user-configured grace period. Null
  /// when no grace timer is armed (grace period zero → lock is immediate).
  Timer? _graceTimer;

  /// The configured grace period, cached so lifecycle handling stays
  /// synchronous: with a zero grace the cover must land inside the lifecycle
  /// callback itself (as it did before grace periods existed), not a
  /// microtask later. Refreshed on start and on every resume — the only
  /// moments the Settings screen can have been visited in between.
  Duration _grace = Duration.zero;

  Future<void> _refreshGrace() async {
    final Duration grace = await _service.lockGrace();
    if (mounted) _grace = grace;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshGrace());
    unawaited(_evaluateLock());
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The root prompt is already behind an opaque lock. Its own completion
    // decides whether to uncover, so lifecycle noise from that system dialog
    // must not recursively launch another prompt.
    if (_authenticating) {
      switch (state) {
        case AppLifecycleState.paused:
        case AppLifecycleState.hidden:
        case AppLifecycleState.detached:
          _rootAuthenticationBackgrounded = true;
          _successfulAuthenticationPendingResume = false;
          _coverForPrivacy();
          break;
        case AppLifecycleState.resumed:
          // A sticky native prompt can continue after returning to the app. A
          // success from that now-visible prompt is valid for this foreground.
          _rootAuthenticationBackgrounded = false;
          break;
        case AppLifecycleState.inactive:
          break;
      }
      return;
    }

    // A prompt initiated from Settings normally causes only `inactive`, which
    // is safe to ignore because the OS dialog obscures the app. If the app is
    // actually paused/hidden during that prompt, remember it and cover now;
    // once the external prompt completes, re-evaluate the persisted setting.
    if (_service.isAuthenticating) {
      switch (state) {
        case AppLifecycleState.paused:
        case AppLifecycleState.hidden:
        case AppLifecycleState.detached:
          _externalAuthenticationBackgrounded = true;
          _coverForPrivacy();
          unawaited(_waitForExternalAuthentication());
          break;
        case AppLifecycleState.resumed:
          if (_externalAuthenticationBackgrounded) {
            unawaited(_waitForExternalAuthentication());
          }
          break;
        case AppLifecycleState.inactive:
          break;
      }
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        // Returning within the grace period cancels the pending lock; the app
        // stays unlocked.
        _graceTimer?.cancel();
        // Pick up grace-period changes made in Settings while foregrounded.
        unawaited(_refreshGrace());
        if (_successfulAuthenticationPendingResume) {
          _successfulAuthenticationPendingResume = false;
          _rootAuthenticationBackgrounded = false;
          setState(() {
            _covered = false;
            _checking = false;
            _error = null;
          });
          break;
        }
        _externalAuthenticationBackgrounded = false;
        if (_covered) unawaited(_evaluateLock());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // With a zero grace period (the default) the app locks as soon as it
        // is really backgrounded (`hidden`/`paused`). With a non-zero grace,
        // the cover/lock land only if the app is still backgrounded when the
        // grace expires. Note the deliberate
        // privacy trade-off of a non-zero grace: the OS app-switcher
        // snapshot may show the uncovered UI.
        _graceTimer?.cancel();
        // `inactive` alone is also what Android reports when the window just
        // loses focus: the Samsung screenshot toolbar, the notification shade,
        // a permission dialog. Covering the app for those made screenshots
        // capture the lock spinner instead of the screen. Real backgrounding
        // always continues to `hidden`/`paused`, which still lock at once.
        if (state == AppLifecycleState.inactive) break;
        if (_grace <= Duration.zero) {
          _coverForPrivacy();
          return;
        }
        _graceTimer = Timer(_grace, () {
          if (!mounted) return;
          // A resume during the grace period cancels the timer; if lifecycle
          // delivery raced, double-check before covering.
          if (WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed) {
            _coverForPrivacy();
          }
        });
        break;
    }
  }

  Future<void> _waitForExternalAuthentication() async {
    if (_waitingForExternalAuthentication) return;
    _waitingForExternalAuthentication = true;
    while (mounted && _service.isAuthenticating) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Give the Settings flow one event-loop turn to persist its new value.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _waitingForExternalAuthentication = false;
    if (!mounted || !_externalAuthenticationBackgrounded) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _externalAuthenticationBackgrounded = false;
    await _evaluateLock();
  }

  void _coverForPrivacy() {
    // Invalidate any in-flight preference/session check. Otherwise a check
    // started in the foreground could finish after the app backgrounds and
    // uncover the UI just as the OS captures its app-switcher snapshot.
    _evaluationId++;
    // A success delivered while the app was only inactive is valid solely for
    // the immediately following resume. If the app transitions farther into
    // the background, discard it and require fresh authentication.
    _successfulAuthenticationPendingResume = false;
    if (!mounted || (_covered && _checking && _error == null)) return;
    setState(() {
      _covered = true;
      _checking = true;
      _error = null;
    });
  }

  Future<void> _evaluateLock() async {
    final int evaluationId = ++_evaluationId;
    if (mounted && !_checking) {
      setState(() {
        _checking = true;
        _error = null;
      });
    }

    late final bool enabled;
    try {
      enabled = await _service.isEnabled();
    } catch (_) {
      // If there is definitely no session, exposing onboarding is safe. If
      // secure storage also fails, assume a session exists and keep the lock.
      bool hasSession = true;
      try {
        hasSession = await (widget.hasStoredSession?.call() ??
            TokenStorage.hasStoredSession());
      } catch (_) {
        hasSession = true;
      }
      if (!mounted || evaluationId != _evaluationId) return;
      setState(() {
        _covered = hasSession;
        _checking = false;
        _error = hasSession
            ? 'Could not read biometric settings. Retry or log out.'
            : null;
      });
      return;
    }
    bool hasSession = false;
    if (enabled) {
      try {
        hasSession = await (widget.hasStoredSession?.call() ??
            TokenStorage.hasStoredSession());
      } catch (_) {
        // Secure-storage access can fail transiently while the device is
        // unlocking. Fail closed and authenticate rather than exposing a
        // potentially active session.
        hasSession = true;
      }
    }
    if (!mounted || evaluationId != _evaluationId) return;

    if (!enabled || !hasSession) {
      // An opt-in must never carry over to a different login after the stored
      // session is gone or invalid.
      if (enabled && !hasSession) {
        await _service.setEnabled(false);
        if (!mounted || evaluationId != _evaluationId) return;
      }
      setState(() {
        _covered = false;
        _checking = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _covered = true;
      _checking = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && evaluationId == _evaluationId) {
        unawaited(_authenticate());
      }
    });
  }

  Future<void> _authenticate() async {
    if (_authenticating || _loggingOut) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });

    final BiometricAuthenticationResult result = await _service.authenticate();
    if (!mounted) return;

    // A concurrent logout/session-expiry clears the opt-in. Re-evaluate so the
    // newly displayed login screen is not stranded behind a stale lock.
    if (!result.authenticated &&
        result.error?.code == BiometricErrorCode.disabled) {
      setState(() {
        _authenticating = false;
        _checking = true;
        _error = null;
      });
      unawaited(_evaluateLock());
      return;
    }

    setState(() {
      _authenticating = false;
      if (result.authenticated) {
        final AppLifecycleState? lifecycleState =
            WidgetsBinding.instance.lifecycleState;
        if (lifecycleState == AppLifecycleState.resumed ||
            (lifecycleState == null && !_rootAuthenticationBackgrounded)) {
          // Widget tests, and a very early real-app startup before the first
          // platform lifecycle message, can have no lifecycle state yet. It
          // is safe to accept that success only when no background transition
          // occurred while the native prompt was pending.
          _covered = false;
          _checking = false;
          _error = null;
        } else if (lifecycleState == AppLifecycleState.inactive &&
            !_rootAuthenticationBackgrounded) {
          // Some platforms deliver the native success just before `resumed`.
          // Keep the cover for that brief interval, then consume the success.
          _successfulAuthenticationPendingResume = true;
          _covered = true;
          _checking = true;
          _error = null;
        } else {
          // A pause/hidden transition happened while the prompt was pending.
          // Discard this success and require a fresh unlock on next resume.
          _covered = true;
          _checking = true;
          _error = null;
        }
      } else {
        _covered = true;
        _checking = false;
        _error = result.error?.message ??
            'Biometric authentication was not completed. Please try again.';
      }
    });
  }

  Future<void> _logout() async {
    if (_loggingOut || _authenticating) return;
    setState(() {
      _loggingOut = true;
      _error = null;
    });
    try {
      await widget.onLogout();
      if (!mounted) return;
      setState(() {
        _loggingOut = false;
        _covered = false;
        _checking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loggingOut = false;
        _covered = true;
        _checking = false;
        _error = 'Could not log out safely. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_covered,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            excluding: _covered,
            child: IgnorePointer(
              ignoring: _covered,
              child: widget.child,
            ),
          ),
          if (_covered)
            _BiometricLockView(
              checking: _checking,
              authenticating: _authenticating,
              loggingOut: _loggingOut,
              error: _error,
              onUnlock: _authenticate,
              onLogout: _logout,
            ),
        ],
      ),
    );
  }
}

class _BiometricLockView extends StatelessWidget {
  const _BiometricLockView({
    required this.checking,
    required this.authenticating,
    required this.loggingOut,
    required this.error,
    required this.onUnlock,
    required this.onLogout,
  });

  final bool checking;
  final bool authenticating;
  final bool loggingOut;
  final String? error;
  final VoidCallback onUnlock;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: checking
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: OpenFamilyMark(size: 88)),
                        const SizedBox(height: 24),
                        Text(
                          'OpenFamily is locked',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Authenticate to view your private family map.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 20),
                          Text(
                            error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.statusRed,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        const SizedBox(height: 28),
                        FilledButton.icon(
                          onPressed:
                              authenticating || loggingOut ? null : onUnlock,
                          icon: authenticating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.fingerprint),
                          label: Text(
                            authenticating ? 'Authenticating…' : 'Unlock',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed:
                              authenticating || loggingOut ? null : onLogout,
                          child: Text(
                            loggingOut ? 'Logging out…' : 'Log out instead',
                          ),
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
