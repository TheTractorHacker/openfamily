import 'package:flutter/material.dart';

import '../services/speed_units.dart';

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
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Speed and distance units',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<UnitSystem>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<UnitSystem>>[
                  ButtonSegment<UnitSystem>(
                    value: UnitSystem.imperial,
                    label: Text('mph / mi'),
                  ),
                  ButtonSegment<UnitSystem>(
                    value: UnitSystem.metric,
                    label: Text('km/h / km'),
                  ),
                ],
                selected: <UnitSystem>{units},
                onSelectionChanged: (Set<UnitSystem> s) =>
                    UnitPreferenceService.setUnits(s.first),
              ),
            ],
          ),
        );
      },
    );
  }
}
