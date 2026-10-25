import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'screens/app_shell.dart';
import 'screens/server_config_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/background_credential_store.dart';
import 'services/background_location_service.dart';
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
  WidgetsFlutterBinding.ensureInitialized();
  // Plugin callbacks must be registered before the first frame so a
  // UnifiedPush/APNs token arriving at launch is not dropped.
  PushService.initialize();
  await ThemePreferenceService.load();
  await MapStylePreferenceService.load();
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
        return MaterialApp(
          title: 'OpenFamily',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: preference.themeMode,
          builder: (context, child) => BiometricAppLock(
            onLogout: _handleBiometricLogout,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const _SessionGate(),
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
    // Load the runtime server URL (shared_preferences → ServerConfig).
    await ServerConfig.instance.load();

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

    if (!ServerConfig.instance.isConfigured) {
      return _GateResult.needsServerConfig;
    }

    await TileConfig.instance.refresh();

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
    // The gate refreshes the session through the 30-day refresh token when
    // the 15-minute access token has expired, and it never destroys the
    // session on a transport failure — only a definitive server rejection
    // (or an empty token store) clears local credentials.
    final SessionGateResult session = await ApiClient.checkSession();
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
        await TokenStorage.clear();
        return _GateResult.noSession;
      case SessionGateResult.none:
        return _GateResult.noSession;
    }
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
            return const AppShell();
          default:
            return const WelcomeScreen();
        }
      },
    );
  }
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
