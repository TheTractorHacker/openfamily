import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;

import '../services/auth_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/biometric_service.dart';
import '../services/location_sharing_service.dart';
import '../services/push_service.dart';
import '../services/server_config.dart';
import '../services/map_style_preference.dart';
import '../services/theme_preference.dart';
import '../theme/app_theme.dart';
import '../widgets/dot_grid.dart';
import '../widgets/ds/ds.dart';
import '../widgets/units_setting_tile.dart';
import 'profile_screen.dart';
import 'circles_screen.dart';
import 'families_screen.dart';
import 'server_config_screen.dart';
import 'welcome_screen.dart';
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
        'OpenFamily is fully stopped. Off unregisters this device.';
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
          'OpenFamily is fully stopped. Off unregisters this device.';
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

/// The Settings screen. Account profile is server-backed; the remaining
/// location and notification values are local toggles for now.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _locationSharing = true;
  bool _locationSharingLoading = true;
  bool _notifications = true;
  bool _notificationsLoading = true;
  bool _loggingOut = false;
  final bool _deletingAccount = false;
  final BiometricService _biometricService = BiometricService.instance;
  bool _biometricLoading = true;
  bool _biometricUpdating = false;
  bool _biometricEnabled = false;
  BiometricAvailability? _biometricAvailability;
  String? _biometricError;
  Duration _lockGrace = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadBiometricSettings();
    _loadLocationSharing();
    _loadPushNotifications();
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

    final List<BiometricType> enrolled = availability.enrolledBiometrics;
    final bool hasFace = enrolled.contains(BiometricType.face);
    final bool hasFingerprint = enrolled.contains(BiometricType.fingerprint);
    final String method = hasFace && hasFingerprint
        ? 'face or fingerprint recognition'
        : hasFace
            ? 'face recognition'
            : hasFingerprint
                ? 'your fingerprint'
                : 'your biometrics';
    return _biometricEnabled
        ? 'Require $method when opening or returning to the app.'
        : 'Use $method to protect your private family map.';
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

  @override
  Widget build(BuildContext context) {
    void push(Widget page) => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    final bool busy = _loggingOut || _deletingAccount;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: DotGridBackground(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              children: [
            const DsSectionHeader('Account'),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.person_outline),
              title: 'Profile',
              chevron: true,
              onTap: () => push(const ProfileScreen()),
            ),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.group_outlined),
              title: 'Family',
              chevron: true,
              onTap: () => push(const FamiliesScreen()),
            ),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.groups_outlined),
              title: 'Circles',
              subtitle: 'All your circles and location sharing',
              chevron: true,
              onTap: () => push(const CirclesScreen()),
            ),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.dns_outlined),
              title: 'Server',
              subtitle: ServerConfig.instance.apiBaseUrl.isEmpty
                  ? 'Not set'
                  : ServerConfig.instance.apiBaseUrl,
              chevron: true,
              onTap: _changeServer,
            ),
            const DsSectionHeader('Appearance'),
            const _AppearanceTile(),
            const _MapStyleTile(),
            const UnitsSettingTile(),
            const DsSectionHeader('Privacy & Security'),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.shield_outlined),
              title: 'Security',
              subtitle: 'Two-factor, sessions, password, your data',
              chevron: true,
              onTap: () => push(const SecurityScreen()),
            ),
            DsToggleRow(
              icon: Icons.fingerprint,
              title: 'Biometric unlock',
              subtitle: _biometricSubtitle,
              subtitleColor:
                  _biometricError == null ? null : AppColors.statusRed,
              value: _biometricEnabled,
              onChanged: !_biometricLoading &&
                      !_biometricUpdating &&
                      ((_biometricAvailability?.isAvailable ?? false) ||
                          _biometricEnabled)
                  ? _setBiometricEnabled
                  : null,
            ),
            if (_biometricEnabled)
              _LockDelayRow(
                value: _lockGrace,
                onChanged: _biometricUpdating ? null : _setLockGrace,
              ),
            const DsSectionHeader('Location'),
            DsToggleRow(
              icon: Icons.location_on_outlined,
              title: 'Location sharing',
              subtitle: 'When off, this device stops reporting your position.',
              value: _locationSharing,
              onChanged: _locationSharingLoading ? null : _setLocationSharing,
            ),
            if (BatteryOptimizationService.isSupported)
              DsListRow(
                leading:
                    DsListRow.iconTile(context, Icons.battery_alert_outlined),
                title: 'Background updates',
                subtitle: 'Let OpenFamily run freely so your location stays '
                    'fresh when the app is closed.',
                chevron: true,
                onTap: BatteryOptimizationService.openSettings,
              ),
            const DsSectionHeader('Notifications'),
            DsToggleRow(
              icon: Icons.notifications_outlined,
              title: 'Push notifications',
              subtitle: pushNotificationsSubtitle(isWeb: kIsWeb),
              value: _notifications,
              onChanged: _notificationsLoading ? null : _setPushNotifications,
            ),
            const DsSectionHeader('About'),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.privacy_tip_outlined),
              title: 'Privacy policy',
              chevron: true,
              onTap: () => push(const PrivacyPolicyScreen()),
            ),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.info_outline),
              title: 'OpenFamily',
              subtitle: 'Version 0.1.0',
            ),
            const SizedBox(height: AppSpace.lg),
            const Divider(height: 1),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.logout,
                  color: AppColors.sosRed),
              title: 'Log Out',
              destructive: true,
              onTap: busy ? null : _logout,
            ),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.delete_forever,
                  color: AppColors.sosRed),
              title: 'Delete account',
              destructive: true,
              onTap: busy ? null : _deleteAccount,
            ),
            const SizedBox(height: AppSpace.xxl),
          ],
        ),
          ),
        ),
      ),
    );
  }
}

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
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.sm,
        AppSpace.xl,
        AppSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DsListRow.iconTile(context, Icons.lock_clock_outlined),
              const SizedBox(width: AppSpace.md),
              const Expanded(child: Text('Lock delay', style: AppType.body)),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'How long the app can stay in the background before it locks. '
            'Longer delays are convenient but let the recents screen show '
            'your family map.',
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.sm),
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

class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemePreference>(
      valueListenable: ThemePreferenceService.preference,
      builder: (context, preference, _) {
        return DsChoiceSetting<ThemePreference>(
          title: 'Theme',
          description: preference == ThemePreference.system
              ? 'Following this device. Light is Ice, dark is Night.'
              : preference == ThemePreference.light
                  ? 'Ice. This device setting is ignored.'
                  : 'Night. This device setting is ignored.',
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
          description: preference == MapStylePreference.light
              ? 'Always the light map, even when the app is dark.'
              : preference == MapStylePreference.dark
                  ? 'Always the dark map.'
                  : 'The map follows the app theme.',
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
