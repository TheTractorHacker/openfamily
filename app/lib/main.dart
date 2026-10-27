import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/login_screen.dart';
import 'screens/app_shell.dart';
import 'screens/join_circle_screen.dart';
import 'screens/server_config_screen.dart';
import 'screens/sign_up_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/accent_preference.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/background_credential_store.dart';
import 'services/background_location_service.dart';
import 'services/deep_link_service.dart';
import 'services/invite_link.dart';
import 'services/pending_invite.dart';
import 'services/perf/perf_monitor.dart';
import 'services/push_service.dart';
import 'services/server_config.dart';
import 'services/session_gate.dart';
import 'services/map_style_preference.dart';
import 'services/theme_preference.dart';
import 'services/tile_config.dart';
import 'services/token_storage.dart';
import 'theme/app_theme.dart';
import 'widgets/biometric_app_lock.dart';
import 'widgets/dot_grid.dart';
import 'widgets/openfamily_brand.dart';

/// Global navigator key so non-widget code (e.g. [ApiClient]) can navigate on
/// session expiry.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  final PerfMonitor perf = PerfMonitor.instance..markMainStart();
  WidgetsFlutterBinding.ensureInitialized();
  perf
    ..attach()
    ..watchFirstFrame();
  // Deliberately draw behind the status and gesture bars (enforced on
  // Android 15+ anyway); every screen pads via MediaQuery insets. Not awaited:
  // it is a fire-and-forget platform call and must not delay the first frame.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  // Plugin callbacks must be registered before the first frame so a
  // UnifiedPush/APNs token arriving at launch is not dropped.
  PushService.initialize();
  // The three stored settings the first frame depends on (theme, map style,
  // server URL) are read together instead of one after another.
  await perf.timeStep(
    'prefs',
    () => Future.wait<void>(<Future<void>>[
      ThemePreferenceService.load(),
      AccentPreferenceService.load(),
      MapStylePreferenceService.load(),
      ServerConfig.instance.load(),
    ]),
  );
  runApp(const OpenFamilyApp());
}

/// Root widget for the OpenFamily app.
class OpenFamilyApp extends StatefulWidget {
  const OpenFamilyApp({super.key});

  @override
  State<OpenFamilyApp> createState() => _OpenFamilyAppState();
}

class _OpenFamilyAppState extends State<OpenFamilyApp> {
  @override
  void initState() {
    super.initState();
    // When a session expires mid-use (refresh fails), redirect to login.
    ApiClient.onSessionExpired = _handleSessionExpired;
    DeepLinkService.listen(_handleInviteLink);
  }

  /// An invite link opened while the app is running.
  Future<void> _handleInviteLink(InviteLink link) async {
    final bool accepted = await PendingInvite.accept(link);
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return;
    if (!accepted) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.maybeOf(navigator.context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'This invite is for a different server than the one this app '
            'uses. Change the server in Settings first.',
          ),
        ),
      );
      return;
    }
    final SessionGateResult session = await ApiClient.checkSession();
    final bool signedIn = session == SessionGateResult.valid ||
        session == SessionGateResult.unreachable;
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => signedIn
          ? JoinCircleScreen(initialCode: link.code)
          : const SignUpScreen(),
    ));
  }

  void _handleSessionExpired() {
    // Stop background reporting: the session is dead and the background isolate
    // can no longer authenticate.
    BackgroundLocationService.stop();
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return;
    navigator.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _handleBiometricLogout() async {
    // Let failures propagate to BiometricAppLock so protected content stays
    // covered unless credential deletion was verified.
    await AuthService.logout();
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) {
      throw StateError('The app navigator is unavailable.');
    }
    navigator.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemePreference>(
      valueListenable: ThemePreferenceService.preference,
      builder: (context, preference, _) {
        return ValueListenableBuilder<Color?>(
          valueListenable: AccentPreferenceService.effective,
          builder: (context, accent, _) => MaterialApp(
          title: 'OpenFamily',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[PerfRouteObserver()],
          theme: buildLightTheme(accent: accent),
          darkTheme: buildDarkTheme(accent: accent),
          themeMode: preference.themeMode,
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            // Bar icon colours follow the app theme, not the OS theme.
            value: systemOverlayFor(Theme.of(context).brightness),
            child: BiometricAppLock(
              onLogout: _handleBiometricLogout,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: const _SessionGate(),
        ),
        );
      },
    );
  }
}

/// Resolves the persisted session before showing the first screen, so a
/// logged-in user is routed to the map instead of being dumped into onboarding.
///
/// The gate first loads the runtime server config (from `shared_preferences`
/// if the compile-time dart-define was empty), then checks whether a valid
/// session exists.
class _SessionGate extends StatefulWidget {
  const _SessionGate();

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  late final Future<_GateResult> _result = _init();

  Future<_GateResult> _init() async {
    final PerfMonitor perf = PerfMonitor.instance;
    // Load the runtime server URL (shared_preferences → ServerConfig). Already
    // done in main(); this returns immediately then.
    await ServerConfig.instance.load();

    // Launched from an invite link: adopt its server (when none is set yet)
    // and keep the code for the join/sign-up form.
    final InviteLink? launchLink = await DeepLinkService.initialLink();
    if (launchLink != null) await PendingInvite.accept(launchLink);

    if (!ServerConfig.instance.isConfigured) {
      // Housekeeping only; nothing else to wait for.
      unawaited(_housekeeping());
      return _GateResult.needsServerConfig;
    }

    // Everything below is independent of each other, so it runs together
    // instead of as a chain of awaits in front of the first screen:
    //  * housekeeping: legacy credential cleanup + syncing the background
    //    isolate's copy of the base URL and device id;
    //  * the operator config (tile style), which the map needs anyway;
    //  * the session check (token reads and, when needed, a refresh call).
    final List<Object?> results = await perf.timeStep(
      'gate',
      () => Future.wait<Object?>(<Future<Object?>>[
        _housekeeping(),
        TileConfig.instance.refresh().then<Object?>((_) => null),
        ApiClient.checkSession(),
      ]),
    );
    final SessionGateResult session = results[2] as SessionGateResult;
    // The gate refreshes the session through the 30-day refresh token when
    // the 15-minute access token has expired, and it never destroys the
    // session on a transport failure — only a definitive server rejection
    // (or an empty token store) clears local credentials.
    switch (session) {
      case SessionGateResult.valid:
      case SessionGateResult.unreachable:
        // Unreachable (offline/5xx): keep the session and open the map; the
        // individual API calls surface connectivity errors on their own.
        return _GateResult.hasSession;
      case SessionGateResult.expired:
        // The server rejected the refresh token: the session is truly dead.
        // Clearing also resets the biometric opt-in so it can never carry
        // over to a future account on the same device.
        await TokenStorage.clear(reason: 'gate: refresh rejected');
        return _GateResult.noSession;
      case SessionGateResult.none:
        return _GateResult.noSession;
    }
  }

  /// Best-effort local cleanup and background-credential sync; never throws.
  Future<Object?> _housekeeping() async {
    // Drop plaintext background credentials left by older builds (MOB-002).
    await BackgroundCredentialStore.migrateLegacyPrefs();

    // Remove the path-only local photo pointer used by an older avatar
    // implementation. Current avatars are private authenticated bytes and are
    // never persisted as a device file path.
    try {
      await TokenStorage.removeLegacyProfilePhotoPath();
    } catch (_) {
      // A secure-storage hiccup should not prevent the app from starting; a
      // later launch or logout will retry this idempotent cleanup.
    }

    if (!ServerConfig.instance.isConfigured) return null;

    // Keep the background isolate's secure copy of the base URL and device id
    // current.
    try {
      await BackgroundCredentialStore.sync(
        apiBaseUrl: ServerConfig.instance.apiBaseUrl,
        deviceId: await TokenStorage.readDeviceId() ?? '',
      );
    } catch (_) {
      // Secure-storage hiccup: the next login/start retries.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_GateResult>(
      future: _result,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashScreen();
        }
        switch (snapshot.data) {
          case _GateResult.needsServerConfig:
            return const ServerConfigScreen();
          case _GateResult.hasSession:
            final String? code = PendingInvite.code;
            if (code == null) return const AppShell();
            return _OpenJoinAfterBuild(code: code, child: const AppShell());
          default:
            if (PendingInvite.code != null) return const SignUpScreen();
            return const WelcomeScreen();
        }
      },
    );
  }
}

/// Shows [child] and then pushes the join screen pre-filled with [code], for a
/// signed-in user who launched the app from an invite link.
class _OpenJoinAfterBuild extends StatefulWidget {
  const _OpenJoinAfterBuild({required this.code, required this.child});

  final String code;
  final Widget child;

  @override
  State<_OpenJoinAfterBuild> createState() => _OpenJoinAfterBuildState();
}

class _OpenJoinAfterBuildState extends State<_OpenJoinAfterBuild> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => JoinCircleScreen(initialCode: widget.code),
      ));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum _GateResult { needsServerConfig, hasSession, noSession }

/// A minimal loading screen shown while the persisted session is resolved.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Scaffold(
      body: DotGridBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const OpenFamilyMark(size: 104),
              const SizedBox(height: 16),
              Text(
                'OpenFamily',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: brand.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
