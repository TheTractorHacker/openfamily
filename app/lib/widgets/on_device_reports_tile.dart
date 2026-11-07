import 'package:flutter/material.dart';

import '../services/e2ee/private_runtime.dart';
import '../services/processing/on_device_setting.dart';

/// "Compute driving reports on this phone": off by default, with the battery and CPU warning.
/// Setting key: [OnDeviceReportsSetting.kvKey].
class OnDeviceReportsTile extends StatefulWidget {
  const OnDeviceReportsTile({super.key});

  @override
  State<OnDeviceReportsTile> createState() => _OnDeviceReportsTileState();
}

class _OnDeviceReportsTileState extends State<OnDeviceReportsTile> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    OnDeviceReportsSetting.isOn(PrivateRuntime.instance.kv).then((bool v) {
      if (mounted) setState(() => _on = v);
    });
  }

  Future<void> _toggle(bool v) async {
    setState(() => _on = v);
    await OnDeviceReportsSetting.set(PrivateRuntime.instance.kv, v);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: const ValueKey<String>('on-device-reports-switch'),
      value: _on ?? false,
      onChanged: _on == null ? null : _toggle,
      title: const Text('Compute driving reports on this phone'),
      subtitle: const Text(
        'Off by default. When on, this phone works out your trips, driving figures and weekly summary and shares them '
        'with your circle. This uses battery and processing power, so it runs in small batches and only now and then. '
        'When off, reports need the server.',
      ),
    );
  }
}
