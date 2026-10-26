import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/battery_optimization_service.dart';
import '../services/family_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/onboarding_step_indicator.dart';
import 'create_or_join_circle_screen.dart';
import 'app_shell.dart';

/// Walks the user through the onboarding permissions — location ("Always
/// Allow" for background tracking), notifications, and (on supported devices)
/// motion & fitness — explaining WHY each is needed (privacy-first).
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

/// One permission step: what to request, its icon, and the "why" copy.
class _PermissionStep {
  const _PermissionStep({
    this.permission,
    required this.icon,
    required this.title,
    required this.why,
    required this.consequence,
    required this.buttonLabel,
    this.optional = false,
    this.battery = false,
  });

  /// Null for the battery step, which is not a runtime permission.
  final OnboardingPermission? permission;
  final IconData icon;
  final String title;
  final String why;
  final String consequence;
  final String buttonLabel;

  /// Whether this permission is optional (motion & fitness is only requested
  /// on devices that support it, and is clearly marked optional).
  final bool optional;

  /// The Android battery-optimization exemption step.
  final bool battery;
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final List<_PermissionStep> _steps = <_PermissionStep>[];
  final List<PermissionState?> _states = <PermissionState?>[];

  final PageController _controller = PageController();
  int _index = 0;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    // Location and notifications are always requested. Motion & fitness is
    // added asynchronously only on devices that support it (iOS, or Android
    // with Google Play Services available).
    _steps.addAll(_baseSteps());
    _states.addAll(List<PermissionState?>.filled(_steps.length, null));
    _loadMotionStep();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static List<_PermissionStep> _baseSteps() => <_PermissionStep>[
        const _PermissionStep(
          permission: OnboardingPermission.location,
          icon: Icons.location_on,
          title: 'Location access',
          why: 'OpenFamily collects and sends your precise location to your '
              'configured server to enable family location sharing, location '
              'history, and arrival and departure alerts, even when the app '
              'is closed or not in use. Your family members and server '
              'administrator can view shared locations. Choose "Always Allow" '
              'to enable background location sharing.',
          consequence:
              'Without "Always Allow", background tracking won\'t work '
              '— your family won\'t see your location when the app is closed.',
          buttonLabel: 'Allow Location',
        ),
        const _PermissionStep(
          permission: OnboardingPermission.notifications,
          icon: Icons.notifications,
          title: 'Notifications',
          why: 'Get gentle alerts when family members arrive at or leave saved '
              'places, and critical alerts in an emergency. We only send what '
              'matters — never marketing.',
          consequence: 'Without notifications, you won\'t get arrival or '
              'departure alerts, or emergency alerts.',
          buttonLabel: 'Allow Notifications',
        ),
      ];

  static const _PermissionStep _motionStep = _PermissionStep(
    permission: OnboardingPermission.motion,
    icon: Icons.directions_walk,
    title: 'Motion & Fitness',
    why: 'Detects when you\'re driving, biking, or walking so your '
        'family sees how you\'re moving — without draining your battery '
        'with constant GPS.',
    consequence: 'Without motion & fitness, the app can\'t tell when '
        'you\'re driving, biking, or walking.',
    buttonLabel: 'Allow Motion',
    optional: true,
  );

  static const _PermissionStep _batteryStep = _PermissionStep(
    icon: Icons.battery_charging_full,
    title: 'Keep updates flowing',
    why: 'Phones put apps to sleep to save battery, which can pause your '
        'location updates when the app is closed. Setting OpenFamily to '
        '"Don\'t optimize" keeps your family\'s map fresh. It only uses '
        'a little extra battery.',
    consequence: 'Without this, your location may go stale while the app is '
        'in the background on some phones.',
    buttonLabel: 'Open battery settings',
    optional: true,
    battery: true,
  );

  /// Adds the motion & fitness step only on devices that support it.
  Future<void> _loadMotionStep() async {
    final bool supported = await PermissionService.supportsMotion();
    if (!mounted) return;
    setState(() {
      if (supported) {
        _steps.add(_motionStep);
        _states.add(null);
      }
      if (BatteryOptimizationService.isSupported) {
        _steps.add(_batteryStep);
        _states.add(null);
      }
    });
  }

  bool get _isLast => _index == _steps.length - 1;

  Future<void> _allow() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final _PermissionStep step = _steps[_index];
    final PermissionState state;
    if (step.battery) {
      // Not a runtime permission: open the system page and move on. The user
      // makes the final choice there.
      final bool opened = await BatteryOptimizationService.openSettings();
      state = opened ? PermissionState.granted : PermissionState.denied;
    } else {
      state = await PermissionService.request(step.permission!);
    }
    if (!mounted) return;
    setState(() {
      _states[_index] = state;
      _requesting = false;
    });
    _advance();
  }

  Future<void> _notNow() async {
    final _PermissionStep step = _steps[_index];
    final bool skip = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Skip ${step.title}?'),
            content: Text(
              '${step.consequence}\n\nYou can enable it later in Settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Enable'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Skip anyway'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted) return;
    if (skip) {
      _advance();
    } else {
      await _allow();
    }
  }

  void _advance() {
    if (_isLast) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: AppMotion.of(context, const Duration(milliseconds: 300)),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    try {
      await FamilyService().fetchFamily();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const AppShell()),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => const CreateOrJoinCircleScreen(),
          ),
        );
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const AppShell()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const CreateOrJoinCircleScreen(),
        ),
      );
    }
  }

  /// Whether the current step needs the user to open system Settings to grant
  /// the permission (the OS won't show a prompt again).
  ///
  /// Two cases:
  /// 1. The permission was permanently denied (the OS refuses to re-prompt).
  /// 2. On iOS 13+, the "Always" location request returns `denied` (NOT
  ///    `permanentlyDenied`) because the OS no longer shows an inline "Always"
  ///    prompt — the user must manually choose "Always" in Settings. Without
  ///    this, the "Open Settings" button never appears and background tracking
  ///    silently fails.
  bool _needsManualSettingsFor(int index) {
    final PermissionState? state = _states[index];
    if (state == PermissionState.permanentlyDenied) return true;
    if (state == PermissionState.denied &&
        _steps[index].permission == OnboardingPermission.location &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Permissions'),
        bottom: const OnboardingStepIndicator(currentStep: 2, totalSteps: 6),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: <Widget>[
                Semantics(
                  label: 'Permission ${_index + 1} of ${_steps.length}',
                  excludeSemantics: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        for (int i = 0; i < _steps.length; i++)
                          AnimatedContainer(
                            duration: AppMotion.of(context, AppMotion.fast),
                            margin: const EdgeInsets.symmetric(
                              horizontal: AppSpace.xs,
                            ),
                            width: i == _index ? 24 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == _index
                                  ? brand.accent
                                  : cs.onSurface.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _controller,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _index = i),
                    children: <Widget>[
                      for (int i = 0; i < _steps.length; i++)
                        _PermissionStepView(
                          step: _steps[i],
                          state: _states[i],
                          needsManualSettings: _needsManualSettingsFor(i),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xxl,
                    AppSpace.sm,
                    AppSpace.xxl,
                    AppSpace.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      DsBusyButton(
                        label: _steps[_index].buttonLabel,
                        busy: _requesting,
                        onPressed: _allow,
                      ),
                      // When the OS won't prompt again, offer a direct path
                      // to system settings.
                      if (_needsManualSettingsFor(_index)) ...<Widget>[
                        const SizedBox(height: AppSpace.sm),
                        DsPillButton(
                          label: 'Open Settings',
                          icon: Icons.settings_outlined,
                          style: DsPillStyle.tonal,
                          onPressed: _requesting
                              ? null
                              : () => PermissionService.openSettings(),
                        ),
                      ],
                      const SizedBox(height: AppSpace.sm),
                      DsPillButton(
                        label: _steps[_index].optional
                            ? 'Skip (optional)'
                            : 'Not now',
                        style: DsPillStyle.outlined,
                        onPressed: _requesting ? null : _notNow,
                      ),
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

/// A single permission step: icon, title, the "why" explanation, and a
/// granted/denied state indicator.
class _PermissionStepView extends StatelessWidget {
  const _PermissionStepView({
    required this.step,
    required this.state,
    required this.needsManualSettings,
  });

  final _PermissionStep step;
  final PermissionState? state;

  /// Whether the user must open system Settings to grant this permission
  /// (permanently denied, or the iOS "Always" request returning `denied`).
  final bool needsManualSettings;

  @override
  Widget build(BuildContext context) {
    final bool granted = state == PermissionState.granted;
    final bool denied = state != null && !granted;
    final bool permanentlyDenied = state == PermissionState.permanentlyDenied;

    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xxl,
        vertical: AppSpace.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ExcludeSemantics(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: brand.accent,
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: Icon(
                granted ? Icons.check : step.icon,
                size: 48,
                color: brand.onAccent,
              ),
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          Semantics(
            header: true,
            child: Text(
              step.title,
              textAlign: TextAlign.center,
              style: AppType.title.copyWith(fontSize: 26),
            ),
          ),
          if (step.optional || granted || denied) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: <Widget>[
                if (step.optional)
                  const DsStatusChip(label: 'Optional', icon: Icons.tune),
                if (granted)
                  const DsStatusChip(label: 'Allowed', icon: Icons.check),
                if (denied)
                  const DsStatusChip(
                    label: 'Not allowed yet',
                    icon: Icons.error_outline,
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.md),
          Text(
            step.why,
            textAlign: TextAlign.center,
            style: AppType.body.copyWith(
              fontWeight: FontWeight.w500,
              height: 1.4,
              color: cs.onSurfaceVariant,
            ),
          ),
          if (denied) DsMessage(
            permanentlyDenied
                ? 'This permission is blocked. Tap "Open Settings" below to '
                    'enable it.'
                : needsManualSettings
                    ? 'On iOS, choose "Always Allow" in Settings to enable '
                        'background tracking. Tap "Open Settings" below.'
                    : 'You can enable this later in Settings.',
            tone: DsTone.info,
          ),
        ],
      ),
    );
  }
}
