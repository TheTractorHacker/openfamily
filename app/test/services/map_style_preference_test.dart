import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openfamily/services/map_style_preference.dart';
import 'package:openfamily/services/map_style_service.dart';
import 'package:openfamily/services/tile_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapStylePreference', () {
    test('defaults to light and ignores unknown values', () {
      expect(MapStylePreferenceX.parse(null), MapStylePreference.light);
      expect(MapStylePreferenceX.parse('nonsense'), MapStylePreference.light);
    });

    test('round-trips through its storage value', () {
      for (final MapStylePreference p in MapStylePreference.values) {
        expect(MapStylePreferenceX.parse(p.storageValue), p);
      }
    });

    test('light stays light and dark stays dark whatever the app theme is', () {
      expect(MapStylePreference.light.resolveDark(appIsDark: true), isFalse);
      expect(MapStylePreference.dark.resolveDark(appIsDark: false), isTrue);
      expect(MapStylePreference.matchApp.resolveDark(appIsDark: true), isTrue);
      expect(MapStylePreference.matchApp.resolveDark(appIsDark: false), isFalse);
    });

    test('the default map style is the light OpenFreeMap style, even in a dark app', () {
      final bool dark =
          MapStylePreference.light.resolveDark(appIsDark: true);
      final MapLayerChoice choice = resolveMapLayer(
        config: TileConfig.instance,
        dark: dark,
      );
      expect(choice.styleUrl, kDefaultLightStyleUrl);
    });

    test('persists and reloads the choice', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await MapStylePreferenceService.setPreference(MapStylePreference.matchApp);
      MapStylePreferenceService.preference.value = MapStylePreference.light;
      expect(await MapStylePreferenceService.load(), MapStylePreference.matchApp);
    });
  });
}
