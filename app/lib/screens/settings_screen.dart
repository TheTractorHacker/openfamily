import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/server_prompts.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:package_info_plus/package_info_plus.dart';

import '../services/accent_preference.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/token_storage.dart';
import '../services/widget_snapshot.dart';
import '../services/battery_optimization_service.dart';
import '../services/biometric_service.dart';
import '../services/location_sharing_service.dart';
import '../services/platform_features.dart';
import '../services/push_service.dart';
import '../services/server_config.dart';
import '../services/map_style_preference.dart';
import '../services/theme_preference.dart';
import '../theme/app_theme.dart';
import '../widgets/dot_grid.dart';
import '../widgets/ds/ds.dart';
import '../widgets/units_setting_tile.dart';
import 'about_screen.dart';
import 'profile_screen.dart';
import 'circles_screen.dart';
import 'diagnostics_screen.dart';
import 'link_device_screen.dart';
import 'driving_detection_screen.dart';
import 'families_screen.dart';
import 'server_config_screen.dart';
import 'watch_settings_screen.dart';
import 'welcome_screen.dart';
import '../services/watch/watch_bridge.dart' show WatchBridge;
import 'notification_settings_screen.dart';
import 'onboarding_screen.dart';
import 'performance_screen.dart';
import 'my_processing_screen.dart';
import 'privacy_policy_screen.dart';
import 'security_screen.dart';

/// Build-time device-preview override. The device-frame preview is served by
/// the web engine but exists to rehearse mobile builds we cannot run (e.g.
/// iOS without a Mac); build it with
/// `--dart-define=OPENFAMILY_PLATFORM_OVERRIDE=ios` (or `android`) so
/// platform-copy reads as that platform. Empty by default, so platform
/// builds and genuine web builds are unaffected.
const String kPreviewPlatformOverride = String.fromEnvironment(
  'OPENFAMILY_PLATFORM_OVERRIDE',
);

/// One-line push-notification guidance for the Settings screen.
///
/// Platform-aware on purpose: Android's guidance (built-in direct channel,
/// optional ntfy/UnifiedPush) must not leak into iOS (whose delivery rides APNs, nothing to
/// install) or the browser preview (where no push transport exists at all).
/// [isWeb] is passed explicitly because `kIsWeb` is a compile-time constant;
/// [previewPlatform] defaults to the build-time override so tests can pass
/// values explicitly.
String pushNotificationsSubtitle({
  required bool isWeb,
  TargetPlatform? platform,
  String previewPlatform = kPreviewPlatformOverride,
}) {
  // Device-preview override: present copy as the rehearsed platform even
  // though the rendering engine is the web.
  if (previewPlatform == 'android') {
    return 'Alerts reach this phone through your own server; nothing to install. '
        'The ntfy app (UnifiedPush) is optional and only adds delivery when '
        'Orbitly is fully stopped. Off unregisters this device.';
  }
  if (previewPlatform == 'ios') {
    return 'Delivered through your server via APNs. Off unregisters this '
        'device.';
  }
  if (isWeb) {
    return 'Push delivery is not available in the browser preview. This '
        'preference is remembered for the installed apps.';
  }
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'Alerts reach this phone through your own server; nothing to install. '
          'The ntfy app (UnifiedPush) is optional and only adds delivery when '
          'Orbitly is fully stopped. Off unregisters this device.';
    case TargetPlatform.iOS:
      return 'Delivered through your server via APNs. Off unregisters this '
          'device.';
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return 'Off unregisters this device from push notifications.';
  }
}

/// What the "Keep me signed in" switch really does, in one short line.
String keepSignedInSubtitle(KeepSignedInStatus status) => switch (status) {
      KeepSignedInStatus.off => 'Off: you sign in when asked',
      KeepSignedInStatus.active => 'On: this phone signs back in',
      KeepSignedInStatus.twoFactor => 'Not possible with two-factor',
      KeepSignedInStatus.waitingForSignIn => 'On: saved at your next sign-in',
    };

/// The long, honest version behind the (i).
String keepSignedInInfo({required bool iOS}) =>
    'If the server ends your sign-in on this phone, Orbitly signs in again by itself with the password saved here, '
    'without asking you.\n\n'
    'This cannot work with two-factor sign-in: Orbitly cannot type the code for you, so with two-factor on '
    'nothing is saved and you are asked to sign in again.\n\n'
    'The password is saved when you sign in with it (turning this on later saves it at your next sign-in). It stays in the '
    '${iOS ? 'iPhone Keychain' : 'Android Keystore'} on this phone only, and is deleted when you turn this off, '
    'change your password or log out.';

/// Counts taps on the version row: [tapsNeeded] taps, each within [window] of
/// the previous one, unlock the hidden Performance screen.
class VersionTapCounter {
  static const int tapsNeeded = 7;
  static const Duration window = Duration(seconds: 2);

  int _count = 0;
  DateTime? _last;

  /// Registers a tap at [now]; true when this tap completes the sequence.
  bool tap(DateTime now) {
    final DateTime? last = _last;
    if (last == null || now.difference(last) > window) _count = 0;
    _last = now;
    _count++;
    if (_count >= tapsNeeded) {
      _count = 0;
      return true;
    }
    return false;
  }
}

/// The Settings screen. Account profile is server-backed; the remaining
/// location and notification values are local toggles for now.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Forgets the remembered server release (tests only).
@visibleForTesting
void resetSettingsServerVersionCache() => _SettingsScreenState._resetServerVersion();

class _SettingsScreenState extends State<SettingsScreen> {
  bool _locationSharing = true;
  bool _locationSharingLoading = true;
  bool _widgetShowFamily = true;
  bool _notifications = true;
  bool _notificationsLoading = true;
  bool _loggingOut = false;
  final bool _deletingAccount = false;
  final BiometricService _biometricService = BiometricService.instance;
  bool _biometricLoading = true;
  bool _biometricUpdating = false;
  bool _biometricEnabled = false;
  bool _keepSignedIn = true;
  KeepSignedInStatus _keepStatus = KeepSignedInStatus.waitingForSignIn;
  bool _advancedOpen = false;
  BiometricAvailability? _biometricAvailability;
  String? _biometricError;
  Duration _lockGrace = Duration.zero;

  /// The server release seen earlier in this app run, and the server it was
  /// read from. A different server (after "Change server") never reuses it.
  static String _serverVersion = '';
  static String _serverVersionFor = '';

  static void _resetServerVersion() {
    _serverVersion = '';
    _serverVersionFor = '';
  }


  final VersionTapCounter _versionTaps = VersionTapCounter();
  String _versionText = 'Version …';

  /// App version from the installed build, plus the server release from the
  /// authenticated /version (best effort; omitted when the server is unreachable).
  Future<void> _loadVersions() async {
    String app = '';
    try {
      app = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    // The server release changes only when the server is updated: ask once per
    // app run instead of on every visit to Settings.
    final String base = ServerConfig.instance.apiBaseUrl;
    String server = _serverVersionFor == base ? _serverVersion : '';
    if (server.isEmpty) {
      try {
        final r = await ApiClient.get('/version');
        final v = r is Map ? r['version'] : null;
        if (v is String && v.isNotEmpty) {
          server = v;
          _serverVersion = v;
          _serverVersionFor = base;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _versionText = [
        if (app.isNotEmpty) 'App $app',
        if (server.isNotEmpty) 'Server $server',
      ].join(' · ');
      if (_versionText.isEmpty) _versionText = 'Version unknown';
    });
  }

  Future<void> _replayWalkthrough() async {
    String id = 'unknown';
    try {
      final Map<String, dynamic> me = await ApiClient.getAccount();
      id = (me['id'] ?? me['user_id'] ?? id).toString();
    } catch (_) {
      // Offline: replay anyway, under a generic key.
    }
    if (!mounted) return;
    await OnboardingScreen.show(context, id);
  }

  void _onVersionTap() {
    if (_versionTaps.tap(DateTime.now())) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PerformanceScreen()),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _loadBiometricSettings();
    _loadKeepSignedIn();
    _loadLocationSharing();
    HomeWidgetService.isEnabled().then((bool v) {
      if (mounted) setState(() => _widgetShowFamily = v);
    });
    _loadPushNotifications();
    _loadVersions();
  }

  Future<void> _loadPushNotifications() async {
    final bool enabled = await PushService.load();
    if (!mounted) return;
    setState(() {
      _notifications = enabled;
      _notificationsLoading = false;
    });
  }

  Future<void> _setPushNotifications(bool enabled) async {
    setState(() => _notifications = enabled);
    await PushService.setEnabled(enabled);
  }

  Future<void> _loadLocationSharing() async {
    final bool enabled = await LocationSharingService.load();
    if (!mounted) return;
    setState(() {
      _locationSharing = enabled;
      _locationSharingLoading = false;
    });
  }

  Future<void> _setLocationSharing(bool enabled) async {
    setState(() => _locationSharing = enabled);
    await LocationSharingService.setEnabled(enabled);
  }

  Future<void> _loadKeepSignedIn() async {
    final bool on = await TokenStorage.keepSignedInEnabled();
    final KeepSignedInStatus status = await TokenStorage.keepSignedInStatus();
    if (mounted) {
      setState(() {
        _keepSignedIn = on;
        _keepStatus = status;
      });
    }
  }

  Future<void> _setKeepSignedIn(bool on) async {
    setState(() => _keepSignedIn = on);
    try {
      await TokenStorage.setKeepSignedIn(on);
      await _loadKeepSignedIn();
    } catch (_) {
      if (!mounted) return;
      setState(() => _keepSignedIn = !on);
    }
  }

  Future<void> _loadBiometricSettings() async {
    try {
      final bool enabled = await _biometricService.isEnabled();
      final BiometricAvailability availability =
          await _biometricService.getAvailability();
      final Duration lockGrace = await _biometricService.lockGrace();
      if (!mounted) return;
      setState(() {
        _biometricEnabled = enabled;
        _biometricAvailability = availability;
        _lockGrace = lockGrace;
        _biometricLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _biometricLoading = false;
        _biometricError =
            'Could not read biometric settings. Please reopen Settings.';
      });
    }
  }

  Future<void> _setBiometricEnabled(bool enabled) async {
    if (_biometricUpdating) return;
    setState(() {
      _biometricUpdating = true;
      _biometricError = null;
    });

    BiometricAvailability availability =
        await _biometricService.getAvailability();
    if (!mounted) return;
    _biometricAvailability = availability;

    if (enabled && !availability.isAvailable) {
      _finishBiometricUpdateWithError(availability.message);
      return;
    }

    // Confirm both opt-in and opt-out while biometrics are available. If the
    // user removed all enrolled biometrics, still let them turn a now-unusable
    // lock off from this already-authenticated session.
    if (enabled || availability.isAvailable) {
      final BiometricAuthenticationResult result =
          await _biometricService.authenticate(
        localizedReason: enabled
            ? 'Confirm your identity to enable biometric unlock.'
            : 'Confirm your identity to disable biometric unlock.',
        requireEnabled: !enabled,
      );
      if (!mounted) return;
      if (!result.authenticated) {
        _finishBiometricUpdateWithError(
          result.error?.message ??
              'Biometric authentication was not completed.',
        );
        return;
      }
    }

    final bool saved = await _biometricService.setEnabled(enabled);
    if (!mounted) return;
    if (!saved) {
      _finishBiometricUpdateWithError(
        'Could not save the biometric setting. Please try again.',
      );
      return;
    }

    setState(() {
      _biometricEnabled = enabled;
      _biometricUpdating = false;
      _biometricError = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled ? 'Biometric unlock enabled.' : 'Biometric unlock disabled.',
        ),
      ),
    );
  }

  Future<void> _setLockGrace(Duration? grace) async {
    if (grace == null) return;
    final bool saved = await _biometricService.setLockGrace(grace);
    if (!mounted) return;
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the lock delay.')),
      );
      return;
    }
    setState(() => _lockGrace = grace);
  }

  void _finishBiometricUpdateWithError(String message) {
    if (!mounted) return;
    setState(() {
      _biometricUpdating = false;
      _biometricError = message;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String get _biometricSubtitle {
    if (_biometricLoading) return 'Checking this device…';
    if (_biometricUpdating) return 'Waiting for confirmation…';
    if (_biometricError != null) return _biometricError!;
    final BiometricAvailability? availability = _biometricAvailability;
    if (availability == null || !availability.isAvailable) {
      return availability?.message ??
          'Biometric authentication is unavailable.';
    }

    return _biometricEnabled ? 'On' : 'Off';
  }

  /// Which way of unlocking the phone offers (for the (i) text).
  String get _biometricMethod {
    final List<BiometricType> enrolled =
        _biometricAvailability?.enrolledBiometrics ?? const <BiometricType>[];
    final bool hasFace = enrolled.contains(BiometricType.face);
    final bool hasFingerprint = enrolled.contains(BiometricType.fingerprint);
    return hasFace && hasFingerprint
        ? 'face or fingerprint recognition'
        : hasFace
            ? 'face recognition'
            : hasFingerprint
                ? 'your fingerprint'
                : 'your biometrics';
  }

  Future<void> _logout() async {
    if (_loggingOut) return;
    final bool sure = await showDsConfirm(
      context,
      title: 'Log out?',
      message: 'You will need to sign in again on this device.',
      confirmLabel: 'Log out',
    );
    if (!sure || !mounted) return;
    setState(() => _loggingOut = true);
    try {
      await AuthService.logout();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loggingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not log out safely. Please try again.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    // Clear the stack so the back button can't return to the (now logged-out)
    // map screen.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  Future<void> _changeServer() async {
    final bool confirmed = await showDsConfirm(
      context,
      title: 'Change server?',
      message: 'You will be signed out. Enter the new server address on the '
          'next screen.',
      confirmLabel: 'Continue',
    );
    if (!confirmed || !mounted) return;
    try {
      await AuthService.logout();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not sign out safely. Please try again.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => const ServerConfigScreen(allowCancel: false),
      ),
      (route) => false,
    );
  }

  /// Account deletion now needs step-up (password, plus a code with 2FA), so
  /// it lives under Security.
  void _deleteAccount() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SecurityScreen()),
    );
  }

  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Whether a row matches the search box: every word typed must appear in
  /// the row's title or its keywords.
  bool _matches(String keys, Widget w) {
    if (_query.isEmpty) return true;
    final String hay = '$keys ${_titleOf(w).toLowerCase()}';
    return _query.split(RegExp(r'\s+')).every(hay.contains);
  }

  /// A section header plus its rows, filtered by the search box.
  List<Widget> _section(String name, List<(String, Widget)> rows) {
    final List<Widget> shown = <Widget>[
      for (final (String keys, Widget w) in rows)
        if (w is! SizedBox && _matches(keys, w)) w,
    ];
    if (shown.isEmpty) return const <Widget>[];
    return <Widget>[DsSectionHeader(name), ...shown];
  }

  static String _titleOf(Widget w) =>
      w is DsListRow ? w.title : (w is DsToggleRow ? w.title : '');

  /// "Advanced": the rarely needed settings, folded away until asked for (or
  /// until a search matches one of them).
  List<Widget> _advanced(List<(String, Widget)> rows) {
    if (_query.isNotEmpty) return _section('Advanced', rows);
    return <Widget>[
      const DsSectionHeader('More'),
      DsListRow(
        key: const Key('settings-advanced'),
        leading: DsListRow.iconTile(context, Icons.tune_outlined, decorative: true),
        title: 'Advanced',
        subtitle: 'Rarely needed settings',
        semanticLabel: _advancedOpen ? 'Advanced, expanded' : 'Advanced, collapsed',
        trailing: Icon(_advancedOpen ? Icons.expand_less : Icons.expand_more),
        onTap: () => setState(() => _advancedOpen = !_advancedOpen),
      ),
      if (_advancedOpen)
        for (final (String _, Widget w) in rows)
          if (w is! SizedBox) w,
    ];
  }

  @override
  Widget build(BuildContext context) {
    void push(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    final bool busy = _loggingOut || _deletingAccount;
    final List<(String, List<(String, Widget)>)> sections = <(String, List<(String, Widget)>)>[
      (
        'Account',
        <(String, Widget)>[
          ('profile name photo', DsListRow(
            leading: DsListRow.iconTile(context, Icons.person_outline, decorative: true),
            title: 'Profile',
            subtitle: 'Your name and photo',
            chevron: true,
            onTap: () => push(const ProfileScreen()),
          )),
          ('theme dark light appearance night ice', const _AppearanceTile()),
          ('keep signed in automatically password', DsToggleRow(
            icon: Icons.lock_clock_outlined,
            title: 'Keep me signed in',
            subtitle: _keepSignedIn
                ? keepSignedInSubtitle(_keepStatus)
                : keepSignedInSubtitle(KeepSignedInStatus.off),
            info: keepSignedInInfo(iOS: PlatformFeatures.isIOS),
            value: _keepSignedIn,
            onChanged: _setKeepSignedIn,
          )),
          ('log out sign out', DsListRow(
            leading: DsListRow.iconTile(context, Icons.logout, color: AppColors.sosRed, decorative: true),
            title: 'Log out',
            destructive: true,
            onTap: busy ? null : _logout,
          )),
        ],
      ),
      (
        'Circle',
        <(String, Widget)>[
          ('circles sharing who sees you', DsListRow(
            leading: DsListRow.iconTile(context, Icons.groups_outlined, decorative: true),
            title: 'Circles',
            subtitle: 'Who sees you',
            chevron: true,
            onTap: () => push(const CirclesScreen()),
          )),
          ('family friends people', DsListRow(
            leading: DsListRow.iconTile(context, Icons.group_outlined, decorative: true),
            title: 'Family & friends',
            chevron: true,
            onTap: () => push(const FamiliesScreen()),
          )),
          ('location sharing pause hide', DsToggleRow(
            icon: Icons.location_on_outlined,
            title: 'Location sharing',
            subtitle: _locationSharing ? 'On: your circles see you' : 'Off: you are hidden',
            info: 'When off, this phone stops reporting your position to all of your circles.',
            value: _locationSharing,
            onChanged: _locationSharingLoading ? null : _setLocationSharing,
          )),
        ],
      ),
      (
        'Notifications',
        <(String, Widget)>[
          ('push notifications', DsToggleRow(
            icon: Icons.notifications_outlined,
            title: 'Push notifications',
            subtitle: _notifications ? 'On' : 'Off',
            info: pushNotificationsSubtitle(isWeb: kIsWeb),
            value: _notifications,
            onChanged: _notificationsLoading ? null : _setPushNotifications,
          )),
          ('notification settings alerts check-ins quiet hours', DsListRow(
            leading: DsListRow.iconTile(context, Icons.tune_outlined, decorative: true),
            title: 'Notification settings',
            subtitle: 'Places, drives, quiet hours',
            chevron: true,
            onTap: () => push(const NotificationSettingsScreen()),
          )),
        ],
      ),
      (
        'Privacy and security',
        <(String, Widget)>[
          ('security password two-factor sessions export', DsListRow(
            leading: DsListRow.iconTile(context, Icons.shield_outlined, decorative: true),
            title: 'Security',
            subtitle: 'Password, two-factor, sessions',
            chevron: true,
            onTap: () => push(const SecurityScreen()),
          )),
          ('biometric fingerprint face lock', DsToggleRow(
            icon: Icons.fingerprint,
            title: 'Biometric unlock',
            subtitle: _biometricSubtitle,
            subtitleColor: _biometricError == null ? null : AppColors.statusRed,
            info: 'Asks for $_biometricMethod when you open or return to the app, to protect your private family map.',
            value: _biometricEnabled,
            onChanged: !_biometricLoading &&
                    !_biometricUpdating &&
                    ((_biometricAvailability?.isAvailable ?? false) || _biometricEnabled)
                ? _setBiometricEnabled
                : null,
          )),
          if (_biometricEnabled)
            ('lock delay', _LockDelayRow(value: _lockGrace, onChanged: _biometricUpdating ? null : _setLockGrace)),
          ('server processing where my data is processed phone only opt out switch off', DsListRow(
            key: const Key('settings-processing'),
            leading: DsListRow.iconTile(context, Icons.smartphone, decorative: true),
            title: 'Server processing',
            subtitle: 'On by default, off per circle',
            info: 'Where your data is processed, circle by circle: by the server (maps, history, trips, driving '
                'reports) or only by your phone. Switch it off for a circle to keep your data on your phone. '
                'Locations stay end-to-end encrypted between phones either way.',
            chevron: true,
            onTap: () => push(const MyProcessingScreen()),
          )),
          ('privacy policy', DsListRow(
            leading: DsListRow.iconTile(context, Icons.privacy_tip_outlined, decorative: true),
            title: 'Privacy policy',
            chevron: true,
            onTap: () => push(const PrivacyPolicyScreen()),
          )),
        ],
      ),
      (
        'Devices',
        <(String, Widget)>[
          ('link another phone new phone encryption keys', DsListRow(
            key: const Key('settings-link-phone'),
            leading: DsListRow.iconTile(context, Icons.phonelink_setup_outlined, decorative: true),
            title: 'Link another phone',
            subtitle: 'Open your circles on a second phone',
            chevron: true,
            onTap: () => push(const LinkDeviceScreen()),
          )),
          ('watch companion', WatchBridge.platformSupported
              ? DsListRow(
                  leading: DsListRow.iconTile(context, Icons.watch_outlined, decorative: true),
                  title: 'Watch',
                  subtitle: WatchBridge.isApple ? 'Apple Watch' : 'Wear OS',
                  chevron: true,
                  onTap: () => push(const WatchSettingsScreen()),
                )
              : const SizedBox.shrink()),
          ('widget home screen', PlatformFeatures.homeWidget
              ? DsToggleRow(
                  icon: Icons.widgets_outlined,
                  title: 'Home screen widget',
                  subtitle: 'Show people on the widget',
                  info: 'Names and status are stored on this phone for the widget. Turning this off removes them.',
                  value: _widgetShowFamily,
                  onChanged: (bool v) {
                    setState(() => _widgetShowFamily = v);
                    HomeWidgetService.setEnabled(v);
                  },
                )
              : const SizedBox.shrink()),
          ('driving detection braking', DsListRow(
            leading: DsListRow.iconTile(context, Icons.speed_outlined, decorative: true),
            title: 'Driving detection',
            subtitle: PlatformFeatures.drivingSensors ? 'Hard braking and fast starts' : PlatformFeatures.notOnIphone,
            chevron: true,
            onTap: () => push(const DrivingDetectionScreen()),
          )),
          ('background battery updates', BatteryOptimizationService.isSupported
              ? DsListRow(
                  leading: DsListRow.iconTile(context, Icons.battery_alert_outlined, decorative: true),
                  title: 'Background updates',
                  subtitle: 'Keep location fresh',
                  chevron: true,
                  onTap: BatteryOptimizationService.openSettings,
                )
              : const SizedBox.shrink()),
        ],
      ),
      (
        'About',
        <(String, Widget)>[
          ('about credits licenses', DsListRow(
            leading: DsListRow.iconTile(context, Icons.info_outline, decorative: true),
            title: 'About Orbitly',
            subtitle: 'Credits and licenses',
            chevron: true,
            onTap: () => push(const AboutScreen()),
          )),
          ('walkthrough tour', DsListRow(
            leading: DsListRow.iconTile(context, Icons.slideshow_outlined, decorative: true),
            title: 'Replay walkthrough',
            chevron: true,
            onTap: _replayWalkthrough,
          )),
        ],
      ),
    ];
    final List<(String, Widget)> advanced = <(String, Widget)>[
      ('diagnostics not reporting problems', DsListRow(
        leading: DsListRow.iconTile(context, Icons.health_and_safety_outlined, decorative: true),
        title: 'Diagnostics',
        subtitle: 'Why updates are missing',
        chevron: true,
        onTap: () => push(const DiagnosticsScreen()),
      )),
      ('server address change', DsListRow(
        leading: DsListRow.iconTile(context, Icons.dns_outlined, decorative: true),
        title: 'Server address',
        subtitle: ServerConfig.instance.apiBaseUrl.isEmpty ? 'Not set' : ServerConfig.instance.apiBaseUrl,
        chevron: true,
        onTap: _changeServer,
      )),
      ('map style light dark', const _MapStyleTile()),
      ('accent color colour', const _AccentTile()),
      ('units miles kilometres kilometers distance speed', const UnitsSettingTile()),
      ('delete account remove', DsListRow(
        leading: DsListRow.iconTile(context, Icons.delete_forever, color: AppColors.sosRed, decorative: true),
        title: 'Delete account',
        destructive: true,
        onTap: busy ? null : _deleteAccount,
      )),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: DotGridBackground(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
            child: Column(
              children: <Widget>[
                // The search field stays put above the list. Inside the list it
                // was recreated every time it scrolled back into view, and each
                // new text field asks the platform for its clipboard, Live Text
                // and text-processing apps (Android answers on the UI thread).
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.xs),
                  child: TextField(
                    key: const Key('settings-search'),
                    controller: _search,
                    onChanged: (String v) => setState(() => _query = v.trim().toLowerCase()),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search settings',
                      isDense: true,
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: <Widget>[
                      UpdateCard(serverHost: ServerConfig.instance.apiBaseUrl),
                      for (final (String name, List<(String, Widget)> rows) in sections) ..._section(name, rows),
                      ..._advanced(advanced),
                      // Seven quick taps open the hidden Performance screen. A bare
                      // GestureDetector keeps the row visually and semantically a plain
                      // static row.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onVersionTap,
                        child: DsListRow(
                          leading: DsListRow.iconTile(context, Icons.info_outline, decorative: true),
                          title: 'Orbitly',
                          subtitle: _versionText,
                        ),
                      ),
                      const SizedBox(height: AppSpace.xxl),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The lock delay: a title, one dropdown, and the long explanation behind (i).
class _LockDelayRow extends StatelessWidget {
  const _LockDelayRow({required this.value, required this.onChanged});

  final Duration value;
  final ValueChanged<Duration?>? onChanged;

  static const List<(Duration, String)> _options = [
    (Duration.zero, 'Immediately'),
    (Duration(seconds: 30), '30 seconds'),
    (Duration(minutes: 1), '1 minute'),
    (Duration(minutes: 5), '5 minutes'),
    (Duration(minutes: 15), '15 minutes'),
  ];

  @override
  Widget build(BuildContext context) {
    final bool compact = DsListRow.compactFor(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? AppSpace.lg : AppSpace.xl,
        AppSpace.sm,
        compact ? AppSpace.lg : AppSpace.xl,
        AppSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!compact) ...[
                DsListRow.iconTile(context, Icons.lock_clock_outlined, decorative: true),
                const SizedBox(width: AppSpace.md),
              ],
              const Expanded(child: Text('Lock delay', style: AppType.body)),
              const InfoHint(
                title: 'Lock delay',
                body: 'How long the app can stay in the background before it locks. '
                    'Longer delays are convenient but let the recents screen show your family map.',
              ),
            ],
          ),
          DropdownButtonFormField<Duration>(
            initialValue: value,
            isExpanded: true,
            onChanged: onChanged,
            decoration: const InputDecoration(labelText: 'Lock after'),
            items: [
              for (final (Duration, String) o in _options)
                DropdownMenuItem(value: o.$1, child: Text(o.$2)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Accent colour: the person's own pick, or "Server default" to follow the
/// operator's choice.
class _AccentTile extends StatelessWidget {
  const _AccentTile();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Color?>(
      valueListenable: AccentPreferenceService.user,
      builder: (context, mine, _) {
        final int? mineRgb = mine == null ? null : mine.toARGB32() & 0xFFFFFF;
        Widget swatch(Color c, String name) {
          final bool on = mineRgb == (c.toARGB32() & 0xFFFFFF);
          return Semantics(
            button: true,
            selected: on,
            label: name,
            child: InkResponse(
              onTap: () => AccentPreferenceService.setUser(c),
              radius: 28,
              child: Container(
                width: kMinTarget - 8,
                height: kMinTarget - 8,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: on ? cs.onSurface : cs.outlineVariant,
                    width: on ? 3 : 1.5,
                  ),
                ),
                child: on
                    ? Icon(Icons.check, size: 20, color: onAccentFor(c))
                    : null,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.sm,
            AppSpace.lg,
            AppSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: const Text('Accent colour', style: AppType.body),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                mine == null ? 'Set by your server' : 'Your own colour',
                style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.md,
                runSpacing: AppSpace.md,
                children: <Widget>[
                  for (final c in kAccentChoices) swatch(c.color, c.name),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              TextButton(
                onPressed: mine == null
                    ? null
                    : () => AccentPreferenceService.setUser(null),
                child: const Text('Use server default'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemePreference>(
      valueListenable: ThemePreferenceService.preference,
      builder: (context, preference, _) {
        return DsChoiceSetting<ThemePreference>(
          title: 'Theme',
          options: const [
            DsChoice(ThemePreference.system, 'System',
                icon: Icons.brightness_auto),
            DsChoice(ThemePreference.light, 'Light',
                icon: Icons.light_mode_outlined),
            DsChoice(ThemePreference.dark, 'Dark',
                icon: Icons.dark_mode_outlined),
          ],
          selected: preference,
          onChanged: ThemePreferenceService.setPreference,
        );
      },
    );
  }
}

class _MapStyleTile extends StatelessWidget {
  const _MapStyleTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MapStylePreference>(
      valueListenable: MapStylePreferenceService.preference,
      builder: (context, preference, _) {
        return DsChoiceSetting<MapStylePreference>(
          title: 'Map style',
          options: const [
            DsChoice(MapStylePreference.light, 'Light',
                icon: Icons.light_mode_outlined),
            DsChoice(MapStylePreference.dark, 'Dark',
                icon: Icons.dark_mode_outlined),
            DsChoice(MapStylePreference.matchApp, 'Match app',
                icon: Icons.brightness_auto),
          ],
          selected: preference,
          onChanged: MapStylePreferenceService.setPreference,
        );
      },
    );
  }
}
