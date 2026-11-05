import 'package:flutter/material.dart';

import '../services/speed_units.dart';
import 'ds/ds.dart';

/// The one units setting: miles and mph, or kilometers and km/h, everywhere
/// the app shows a distance or speed. Defaults to miles.
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
          title: 'Distance & speed units',
          options: const <DsChoice<UnitSystem>>[
            DsChoice<UnitSystem>(UnitSystem.imperial, 'Miles'),
            DsChoice<UnitSystem>(UnitSystem.metric, 'Kilometers'),
          ],
          selected: units,
          onChanged: UnitPreferenceService.setUnits,
        );
      },
    );
  }
}
