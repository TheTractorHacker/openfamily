import 'package:flutter/material.dart';

import '../services/driving/driving_events_service.dart';
import '../services/driving/driving_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Settings > Driving detection: opt-in for on-device hard-braking /
/// rapid-acceleration detection with the phone's motion sensors, and for the
/// "screen activity while moving" estimate. Motion detection is ON by default
/// (turn it off here at any time); the screen-activity estimate is OFF by
/// default.
class DrivingDetectionScreen extends StatefulWidget {
  const DrivingDetectionScreen({super.key, this.api});

  /// Transport override for tests; defaults to the account session.
  final SensorEventsApi? api;

  @override
  State<DrivingDetectionScreen> createState() => _DrivingDetectionScreenState();
}

class _DrivingDetectionScreenState extends State<DrivingDetectionScreen> {
  late final DrivingEventsService _service =
      DrivingEventsService(widget.api ?? const SessionSensorEventsApi());

  bool _loading = true;
  bool _busy = false;
  bool _sensor = false;
  bool _phone = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bool s = await DrivingSettings.sensorEnabled(reload: false);
    final bool p = await DrivingSettings.phoneUseEnabled(reload: false);
    if (!mounted) return;
    setState(() {
      _sensor = s;
      _phone = p && s;
      _loading = false;
    });
  }

  Future<void> _setSensor(bool value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (value) {
        // Tell the server first so a failure leaves the feature off.
        await _service.setServerOptIn(true);
        await DrivingSettings.setSensorEnabled(true);
        await DrivingSettings.markSynced(true);
      } else {
        // Stop sampling immediately; the server note follows. If it fails the
        // state stays unsynced and is retried by the app and the background
        // service.
        await DrivingSettings.setSensorEnabled(false);
        await _service.setServerOptIn(false);
        await DrivingSettings.markSynced(false);
      }
      if (!mounted) return;
      setState(() {
        _sensor = value;
        if (!value) _phone = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sensor = false;
        if (!value) _phone = false;
        _error = value
            ? "Couldn't reach the server, so driving detection stays off. "
                'Try again when you are online.'
            : 'Detection is off on this phone. The server could not be '
                'told right now; the app will tell it as soon as it can, '
                'and no more events are sent meanwhile.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPhone(bool value) async {
    setState(() => _error = null);
    try {
      if (value) {
        // Tell the server first: it rejects phone-use events until it knows.
        await _service.setServerPhoneUse(true);
        await DrivingSettings.setPhoneUseEnabled(true);
      } else {
        await DrivingSettings.setPhoneUseEnabled(false);
        await _service.setServerPhoneUse(false);
      }
      await DrivingSettings.markSynced(true, phoneUse: value);
      if (mounted) setState(() => _phone = value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phone = false;
        _error = value
            ? "Couldn't reach the server, so phone use stays off. "
                'Try again when you are online.'
            : 'Phone use is off on this phone. The server could not be told '
                'right now; the app will tell it as soon as it can.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle body =
        AppType.secondary.copyWith(color: cs.onSurfaceVariant);
    const EdgeInsets pad =
        EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xs);
    return DsPage(
      title: 'Driving detection',
      maxWidth: 640,
      children: <Widget>[
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(AppSpace.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...<Widget>[
          Padding(
            padding: pad,
            child: Align(
              alignment: Alignment.centerLeft,
              child: DsStatusChip(
                icon: _sensor
                    ? Icons.check_circle_outline
                    : Icons.pause_circle_outline,
                label: _sensor
                    ? 'On: checking only while you drive'
                    : 'Off: nothing is recorded',
                color: _sensor ? AppColors.statusGreen : AppColors.statusGrey,
              ),
            ),
          ),
          const Padding(
            padding: pad,
            child: Text(
              'Phone GPS alone misses some sudden stops and hard launches. '
              'This is on by default: your phone also uses its motion sensor '
              'to notice them and adds them to your driving report. Turn the '
              'switch below off at any time to stop it.',
              style: AppType.body,
            ),
          ),
          DsToggleRow(
            icon: Icons.speed_outlined,
            title: 'Detect hard braking and acceleration',
            subtitle: 'Uses the motion sensor, only while you are driving.',
            value: _sensor,
            onChanged: _busy ? null : _setSensor,
          ),
          if (_error != null)
            Padding(
              padding: pad,
              child: Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.error_outline,
                        size: 18, color: AppColors.statusRed),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        _error!,
                        style: AppType.secondary
                            .copyWith(color: AppColors.statusRed),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const DsSectionHeader('What is collected'),
          Padding(
            padding: pad,
            child: Text(
              'The motion sensor runs only while your phone is clearly in a '
              'moving vehicle, and stops a couple of minutes after you stop. '
              'It never runs while you are parked or walking.\n\n'
              'Only detected events leave your phone: the type (hard braking, '
              'rapid acceleration), when it happened, how strong it was and '
              'roughly where. Raw sensor readings are processed on the phone '
              'and thrown away. They are never stored or uploaded.',
              style: body,
            ),
          ),
          const DsSectionHeader('Screen activity while moving'),
          DsToggleRow(
            icon: Icons.phone_android_outlined,
            title: 'Count screen activity while moving',
            subtitle: _sensor
                ? 'Estimate only. Android only.'
                : 'Turn on driving detection first.',
            value: _phone,
            onChanged: _sensor ? _setPhone : null,
          ),
          Padding(
            padding: pad,
            child: Text(
              'When the phone is unlocked while the vehicle is moving fast, '
              'we record how long the screen stayed on. This is a rough '
              'estimate: a passenger using the phone looks the same as a '
              'driver, and we cannot tell a map app from anything else. We '
              'do not see which apps you use.',
              style: body,
            ),
          ),
          const DsSectionHeader('Battery'),
          Padding(
            padding: pad,
            child: Text(
              'Sensors and fast GPS run only during trips, so the extra '
              'battery use is small and limited to the time you drive. '
              'Phone use detection adds almost nothing. Background location '
              'sharing must be on for any of this to work.',
              style: body,
            ),
          ),
          const DsSectionHeader('How it works'),
          Padding(
            padding: pad,
            child: Text(
              '1. Your normal location updates notice you are driving.\n'
              '2. The phone then watches its motion sensor and GPS speed.\n'
              '3. A sudden slowdown or speed-up that matches the GPS speed '
              'change is counted. Bumps, potholes and picking the phone up '
              'are ignored.\n'
              '4. Only the event is sent to your server. Turn the switch off '
              'at any time to stop it and discard anything not yet sent.',
              style: body,
            ),
          ),
          const SizedBox(height: AppSpace.xl),
        ],
      ],
    );
  }
}
