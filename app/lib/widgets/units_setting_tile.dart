import 'package:flutter/material.dart';

import '../services/speed_units.dart';
import 'ds/ds.dart';

/// Settings row choosing mph / km/h for trips and driving reports.
class UnitsSettingTile extends StatefulWidget {
  const UnitsSettingTile({super.key});

  @override
  State<UnitsSettingTile> createState() => _UnitsSettingTileState();
}

class _UnitsSettingTileState extends State<UnitsSettingTile> {
  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UnitSystem>(
      valueListenable: UnitPreferenceService.units,
      builder: (BuildContext context, UnitSystem units, _) {
        return DsChoiceSetting<UnitSystem>(
          title: 'Speed and distance units',
          options: const <DsChoice<UnitSystem>>[
            DsChoice<UnitSystem>(UnitSystem.imperial, 'mph / mi'),
            DsChoice<UnitSystem>(UnitSystem.metric, 'km/h / km'),
          ],
          selected: units,
          onChanged: UnitPreferenceService.setUnits,
        );
      },
    );
  }
}
