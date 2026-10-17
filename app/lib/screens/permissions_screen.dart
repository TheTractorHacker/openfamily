import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/family_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/onboarding_step_indicator.dart';
import 'create_or_join_circle_screen.dart';
import 'map_screen.dart';

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
    required this.permission,
    required this.icon,
    required this.title,
    required this.why,
    required this.consequence,
    required this.buttonLabel,
    this.optional = false,
  });

  final OnboardingPermission permission;
  final IconData icon;
  final String title;
  final String why;
  final String consequence;
  final String buttonLabel;

  /// Whether this permission is optional (motion & fitness is only requested
  /// on devices that support it, and is clearly marked optional).
  final bool optional;
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

  /// Adds the motion & fitness step only on devices that support it.
  Future<void> _loadMotionStep() async {
    final bool supported = await PermissionService.supportsMotion();
    if (!mounted || !supported) return;
    setState(() {
      _steps.add(_motionStep);
      _states.add(null);
    });
  }

  bool get _isLast => _index == _steps.length - 1;

  Future<void> _allow() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final PermissionState state =
        await PermissionService.request(_steps[_index].permission);
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
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    try {
      await FamilyService().fetchFamily();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const MapScreen()),
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
        MaterialPageRoute<void>(builder: (_) => const MapScreen()),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enable permissions'),
        bottom: const OnboardingStepIndicator(currentStep: 2, totalSteps: 6),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Progress dots for the permission sub-steps.
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < _steps.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _index ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _index
                            ? AppColors.purple
                            : AppColors.purple.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _index = i),
                children: [
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
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: _requesting ? null : _allow,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: _requesting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _steps[_index].buttonLabel,
                              style: const TextStyle(fontSize: 16),
                            ),
                    ),
                  ),
                  // When the OS won't prompt again (permanently denied, or the
                  // iOS "Always" request returning `denied`), offer a direct
                  // path to system settings.
                  if (_needsManualSettingsFor(_index)) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _requesting
                          ? null
                          : () => PermissionService.openSettings(),
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Open Settings'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _requesting ? null : _notNow,
                    child: Text(
                      _steps[_index].optional ? 'Skip (optional)' : 'Not now',
                    ),
                  ),
                ],
              ),
            ),
          ],
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

    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 48).clamp(0, double.infinity),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: granted
                      ? AppColors.statusGreen.withValues(alpha: 0.12)
                      : AppColors.surfaceTint,
                ),
                child: Icon(
                  granted ? Icons.check_circle : step.icon,
                  size: 48,
                  color: granted ? AppColors.statusGreen : AppColors.purple,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      step.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (step.optional) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.purple.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Optional',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.purple,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                step.why,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: AppColors.textMuted,
                ),
              ),
              if (denied) ...[
                const SizedBox(height: 16),
                Text(
                  permanentlyDenied
                      ? 'This permission is permanently denied. Tap "Open Settings" '
                          'below to enable it.'
                      : needsManualSettings
                          ? 'On iOS, choose "Always Allow" in Settings to enable '
                              'background tracking. Tap "Open Settings" below.'
                          : 'You can enable this later in Settings.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.statusOrange),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}
