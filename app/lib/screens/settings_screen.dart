import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/biometric_service.dart';
import '../services/location_sharing_service.dart';
import '../services/push_service.dart';
import '../services/server_config.dart';
import '../services/theme_preference.dart';
import '../theme/app_theme.dart';
import '../widgets/dot_grid.dart';
import 'profile_screen.dart';
import 'families_screen.dart';
import 'server_config_screen.dart';
import 'welcome_screen.dart';
import 'privacy_policy_screen.dart';

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
/// Platform-aware on purpose: Android's UnifiedPush guidance ("install the
/// ntfy app") must not leak into iOS (whose delivery rides APNs, nothing to
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
    return 'Android needs the ntfy app (UnifiedPush) so alerts arrive when '
        'OpenFamily is closed. Off unregisters this device.';
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
      return 'Android needs the ntfy app (UnifiedPush) so alerts arrive when '
          'OpenFamily is closed. Off unregisters this device.';
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
  bool _deletingAccount = false;
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
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Change server?'),
          content: const Text(
            'You will be signed out. Enter the new server address on the next screen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
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

  Future<void> _deleteAccount() async {
    if (_deletingAccount) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete account?'),
          content: const Text(
            'This permanently deletes your account, devices, and location '
            'history on this server. If you are the last admin of a family '
            'that still has other people, promote someone else first.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.sosRed),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deletingAccount = true);
    try {
      await ApiClient.deleteAccount();
      await AuthService.logout(notifyServer: false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deletingAccount = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.status == 409
                ? e.message
                : e.status == 404
                    ? 'This server cannot delete accounts yet. Ask the operator to update it.'
                    : e.message,
          ),
        ),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _deletingAccount = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete the account. Try again.')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: DotGridBackground(
        child: ListView(
          children: [
            const _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline, color: AppColors.purple),
            title: const Text('Profile'),
            trailing:
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.group_outlined, color: AppColors.purple),
            title: const Text('Family'),
            trailing:
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FamiliesScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined, color: AppColors.purple),
            title: const Text('Server'),
            subtitle: Text(
              ServerConfig.instance.apiBaseUrl.isEmpty
                  ? 'Not set'
                  : ServerConfig.instance.apiBaseUrl,
            ),
            trailing:
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
            onTap: _changeServer,
          ),
            const Divider(height: 1),
            const _SectionHeader('Appearance'),
            const _AppearanceTile(),
            const Divider(height: 1),
            const _SectionHeader('Privacy & Security'),
          SwitchListTile(
            secondary: const Icon(
              Icons.fingerprint,
              color: AppColors.purple,
            ),
            title: const Text('Biometric unlock'),
            subtitle: Text(
              _biometricSubtitle,
              style: _biometricError == null
                  ? null
                  : const TextStyle(color: AppColors.statusRed),
            ),
            value: _biometricEnabled,
            onChanged: !_biometricLoading &&
                    !_biometricUpdating &&
                    ((_biometricAvailability?.isAvailable ?? false) ||
                        _biometricEnabled)
                ? _setBiometricEnabled
                : null,
          ),
          if (_biometricEnabled) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(
                Icons.lock_clock_outlined,
                color: AppColors.purple,
              ),
              title: const Text('Lock delay'),
              subtitle: const Text(
                'How long the app can stay in the background before it '
                'locks. Longer delays are convenient but let the recents '
                'screen show your family map.',
              ),
              trailing: DropdownButton<Duration>(
                value: _lockGrace,
                underline: const SizedBox.shrink(),
                onChanged: _biometricUpdating ? null : _setLockGrace,
                items: const [
                  DropdownMenuItem(
                    value: Duration.zero,
                    child: Text('Immediately'),
                  ),
                  DropdownMenuItem(
                    value: Duration(seconds: 30),
                    child: Text('30 seconds'),
                  ),
                  DropdownMenuItem(
                    value: Duration(minutes: 1),
                    child: Text('1 minute'),
                  ),
                  DropdownMenuItem(
                    value: Duration(minutes: 5),
                    child: Text('5 minutes'),
                  ),
                  DropdownMenuItem(
                    value: Duration(minutes: 15),
                    child: Text('15 minutes'),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 1),
          const _SectionHeader('Location'),
          SwitchListTile(
            secondary:
                const Icon(Icons.location_on_outlined, color: AppColors.purple),
            title: const Text('Location sharing'),
            subtitle: const Text(
              'When off, this device stops reporting your position.',
            ),
            value: _locationSharing,
            onChanged: _locationSharingLoading ? null : _setLocationSharing,
          ),
          if (BatteryOptimizationService.isSupported)
            ListTile(
              leading: const Icon(
                Icons.battery_alert_outlined,
                color: AppColors.purple,
              ),
              title: const Text('Background updates'),
              subtitle: const Text(
                'Let OpenFamily run freely so your location stays fresh '
                'when the app is closed.',
              ),
              trailing:
                  const Icon(Icons.chevron_right, color: AppColors.textMuted),
                  onTap: BatteryOptimizationService.openSettings,
            ),
          const Divider(height: 1),
          const _SectionHeader('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined,
                color: AppColors.purple),
            title: const Text('Push notifications'),
            subtitle: Text(pushNotificationsSubtitle(isWeb: kIsWeb)),
            value: _notifications,
            onChanged: _notificationsLoading ? null : _setPushNotifications,
          ),
          const Divider(height: 1),
          const _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined, color: AppColors.purple),
            title: const Text('Privacy policy'),
            trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline, color: AppColors.purple),
            title: Text('OpenFamily'),
            subtitle: Text('Version 0.1.0'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: AppColors.sosRed),
            title: const Text(
              'Log Out',
              style: TextStyle(color: AppColors.sosRed),
            ),
            enabled: !_loggingOut && !_deletingAccount,
            onTap: _logout,
          ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: AppColors.sosRed),
              title: const Text(
                'Delete account',
                style: TextStyle(color: AppColors.sosRed),
              ),
              enabled: !_loggingOut && !_deletingAccount,
              onTap: _deleteAccount,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Theme',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                preference == ThemePreference.system
                    ? 'Following this device. Light is Ice, dark is Night.'
                    : preference == ThemePreference.light
                        ? 'Ice. This device setting is ignored.'
                        : 'Night. This device setting is ignored.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<ThemePreference>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<ThemePreference>(
                    value: ThemePreference.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto, size: 18),
                  ),
                  ButtonSegment<ThemePreference>(
                    value: ThemePreference.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined, size: 18),
                  ),
                  ButtonSegment<ThemePreference>(
                    value: ThemePreference.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined, size: 18),
                  ),
                ],
                selected: <ThemePreference>{preference},
                onSelectionChanged: (Set<ThemePreference> next) {
                  if (next.isEmpty) return;
                  ThemePreferenceService.setPreference(next.first);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
