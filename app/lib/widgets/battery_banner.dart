import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';

import '../screens/keep_alive_screen.dart';
import '../services/battery_optimization_service.dart';
import '../services/diagnostics/diag_model.dart' show isSamsungPhone;
import '../services/diagnostics/diagnostics_probe.dart';
import '../theme/app_theme.dart';

/// What the banner knows about this phone's battery exemption.
class BatteryBannerState {
  const BatteryBannerState({required this.exempt, required this.manufacturer});

  /// Android's own "not optimised / Unrestricted" flag. Null: could not be read.
  final bool? exempt;
  final String manufacturer;
}

/// Whether the banner must show: only on a phone that told us it is NOT exempt.
/// An unreadable state shows nothing (never nag on a guess); once exempt the
/// banner is gone for good, there is no "dismiss" while it is still needed.
@visibleForTesting
bool batteryBannerVisible(BatteryBannerState? s) => s != null && s.exempt == false;

/// Phone-user wording for the banner, naming the exact tap path on Samsung.
@visibleForTesting
String batteryBannerText(String manufacturer) => isSamsungPhone(manufacturer)
    ? 'Your phone will put Orbitly to sleep. Tap "Fix now", then choose Battery > Unrestricted. '
        'On Samsung this is the one that matters.'
    : 'Your phone may put Orbitly to sleep when the screen is off, so your family sees you late. '
        'Tap "Fix now" and allow Orbitly to run in the background.';

/// A persistent banner above the map while Orbitly is still subject to battery
/// optimisation. It re-checks whenever the app returns to the foreground (the
/// person comes back from Settings) and disappears by itself once the phone is
/// exempt. It cannot be swiped away, on purpose: this setting decides whether
/// the family can see you with the screen off.
class BatteryBanner extends StatefulWidget {
  const BatteryBanner({super.key, this.read, this.onFix, this.onChecklist});

  /// Test seam for the phone state.
  final Future<BatteryBannerState?> Function()? read;
  final Future<void> Function()? onFix;
  final VoidCallback? onChecklist;

  @override
  State<BatteryBanner> createState() => _BatteryBannerState();
}

class _BatteryBannerState extends State<BatteryBanner> with WidgetsBindingObserver {
  BatteryBannerState? _state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<BatteryBannerState?> _read() async {
    if (!BatteryOptimizationService.isSupported) return null;
    final Map<String, dynamic>? n = await DiagnosticsProbe.nativeState();
    if (n == null) return null;
    return BatteryBannerState(
      exempt: n['ignoringBatteryOptimizations'] as bool?,
      manufacturer: (n['manufacturer'] as String?) ?? '',
    );
  }

  Future<void> _check() async {
    BatteryBannerState? s;
    try {
      s = await (widget.read ?? _read)();
    } catch (_) {
      s = null;
    }
    if (!mounted) return;
    setState(() => _state = s);
  }

  Future<void> _fix() async {
    if (widget.onFix != null) {
      await widget.onFix!();
    } else {
      // The system's one-tap "let Orbitly run in the background?" dialog for this app.
      await BatteryOptimizationService.openSettings();
    }
    if (mounted) await _check();
  }

  void _checklist() {
    if (widget.onChecklist != null) {
      widget.onChecklist!();
      return;
    }
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const KeepAliveScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final BatteryBannerState? s = _state;
    if (!batteryBannerVisible(s)) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Material(
        key: const ValueKey<String>('battery-banner'),
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.battery_alert, size: 20, color: cs.onErrorContainer),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      batteryBannerText(s!.manufacturer),
                      style: AppType.secondary.copyWith(color: cs.onErrorContainer),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    key: const ValueKey<String>('battery-banner-checklist'),
                    onPressed: _checklist,
                    child: const Text('Show all steps'),
                  ),
                  FilledButton(
                    key: const ValueKey<String>('battery-banner-fix'),
                    onPressed: _fix,
                    child: const Text('Fix now'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
