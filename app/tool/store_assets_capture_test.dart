// Regenerate genuine Google Play UI captures with fictional, local-only data.
// Run: flutter test tool/store_assets_capture_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/server_config_screen.dart';
import 'package:openfamily/screens/people_screen.dart';
import 'package:openfamily/screens/places_screen.dart';
import 'package:openfamily/screens/invite_screen.dart';
import 'package:openfamily/screens/map_screen.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('render store screenshots from production widgets',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'location_sharing_enabled': false,
      'push_notifications_enabled': false,
      'wb_suggested_battery_optimization': true
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (_) async => 1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('app.yukams/locator_plugin'),
            (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    await tester.runAsync(() async {
      final font = FontLoader('Ahem');
      font.addFont(Future.value(ByteData.sublistView(
          await File('/System/Library/Fonts/Supplemental/Arial.ttf')
              .readAsBytes())));
      font.addFont(Future.value(ByteData.sublistView(
          await File('/System/Library/Fonts/Supplemental/Arial Bold.ttf')
              .readAsBytes())));
      await font.load();
      final roboto = FontLoader('Roboto');
      roboto.addFont(Future.value(ByteData.sublistView(
          await File('/System/Library/Fonts/Supplemental/Arial.ttf')
              .readAsBytes())));
      await roboto.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(Future.value(ByteData.sublistView(await File(
              '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytes())));
      await icons.load();
    });
    final output = Directory('../assets/google-play/raw')
      ..createSync(recursive: true);
    final key = GlobalKey();
    final baseTheme = buildLightTheme();
    final captureTheme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'Roboto'),
      primaryTextTheme: baseTheme.primaryTextTheme.apply(fontFamily: 'Roboto'),
      listTileTheme: baseTheme.listTileTheme.copyWith(
        titleTextStyle: baseTheme.listTileTheme.titleTextStyle
            ?.copyWith(fontFamily: 'Roboto'),
        subtitleTextStyle: baseTheme.listTileTheme.subtitleTextStyle
            ?.copyWith(fontFamily: 'Roboto'),
      ),
    );
    Future<void> capture(String name, Widget screen, {String? input}) async {
      await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: captureTheme,
              home: screen)));
      await tester.runAsync(() async {
        await precacheImage(
            const AssetImage('assets/branding/openfamily-icon.png'),
            key.currentContext!);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      if (input != null) {
        await tester.enterText(find.byType(TextField).first, input);
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    }

    await capture('01-server', const ServerConfigScreen(),
        input: 'https://family.example.com');
    final roster = ValueNotifier<List<Member>>(const [
      Member(
          id: 'alex',
          name: 'Alex',
          position: LatLng(40.78, -73.97),
          status: MemberStatus.normal,
          batteryPercent: 92,
          address: 'Home',
          movement: MovementType.home,
          avatarColor: AppColors.accent),
      Member(
          id: 'sam',
          name: 'Sam',
          position: LatLng(40.77, -73.96),
          status: MemberStatus.normal,
          batteryPercent: 76,
          address: 'Work',
          movement: MovementType.work,
          avatarColor: AppColors.sky),
      Member(
          id: 'jordan',
          name: 'Jordan',
          position: LatLng(40.76, -73.95),
          status: MemberStatus.normal,
          batteryPercent: 84,
          address: 'School',
          avatarColor: AppColors.statusPurple),
      Member(
          id: 'taylor',
          name: 'Taylor',
          position: LatLng(40.75, -73.94),
          status: MemberStatus.normal,
          batteryPercent: 68,
          address: 'Riverside Park',
          movement: MovementType.bike,
          avatarColor: AppColors.statusOrange),
    ]);
    await capture(
        '02-people', PeopleScreen(circleName: 'Our Family', members: roster));
    roster.dispose();
    await ServerConfig.instance.setUrl('https://family.example.com');
    await http.runWithClient(() async {
      await capture('03-places', const PlacesScreen());
    },
        () => MockClient((request) async {
              dynamic body;
              switch (request.url.path) {
                case '/family':
                  body = {
                    'name': 'Our Family',
                    'role': 'admin',
                    'user_id': 'alex'
                  };
                case '/family/places':
                  body = [
                    {
                      'id': 'home',
                      'name': 'Home',
                      'type': 'home',
                      'lat': 40.78,
                      'lon': -73.97,
                      'radius_meters': 150,
                      'address': 'Maple Avenue'
                    },
                    {
                      'id': 'school',
                      'name': 'School',
                      'type': 'school',
                      'lat': 40.76,
                      'lon': -73.95,
                      'radius_meters': 200,
                      'address': 'Oak Street'
                    },
                    {
                      'id': 'work',
                      'name': 'Work',
                      'type': 'work',
                      'lat': 40.77,
                      'lon': -73.96,
                      'radius_meters': 100,
                      'address': 'Park Avenue'
                    },
                    {
                      'id': 'gym',
                      'name': 'Gym',
                      'type': 'gym',
                      'lat': 40.75,
                      'lon': -73.94,
                      'radius_meters': 100,
                      'address': 'River Road'
                    },
                  ];
                case '/family/geofences':
                  body = [
                    for (final id in ['home', 'school', 'work'])
                      {
                        'id': 'g-$id',
                        'place_id': id,
                        'user_id': 'alex',
                        'enabled': true
                      }
                  ];
                default:
                  throw StateError(
                      'Unexpected network request: ${request.url}');
              }
              return http.Response(jsonEncode(body), 200,
                  headers: {'content-type': 'application/json'});
            }));
    await capture('04-invite', const InviteScreen(circleName: 'Our Family'));
    final requestedTiles = <String>{};
    await http.runWithClient(() async {
      await capture('05-map', const MapScreen());
    },
        () => MockClient((request) async {
              if (request.url.host == 'tile.openstreetmap.org') {
                requestedTiles.add(request.url.toString());
                File('../assets/google-play/tile-requests.txt')
                    .writeAsStringSync(requestedTiles.join('\n'));
                final tile =
                    File('../assets/google-play/tiles${request.url.path}');
                return http.Response.bytes(
                    tile.existsSync()
                        ? tile.readAsBytesSync()
                        : File('assets/branding/openfamily-icon.png')
                            .readAsBytesSync(),
                    200,
                    headers: {'content-type': 'image/png'});
              }
              dynamic body;
              switch (request.url.path) {
                case '/family':
                  body = {
                    'name': 'Our Family',
                    'role': 'admin',
                    'user_id': 'alex'
                  };
                case '/family/members':
                  body = [
                    for (final member in [
                      ['alex', 'Alex', 40.7800, -73.9760, 92],
                      ['sam', 'Sam', 40.7730, -73.9650, 76],
                      ['jordan', 'Jordan', 40.7650, -73.9790, 84],
                      ['taylor', 'Taylor', 40.7860, -73.9560, 68],
                    ])
                      {
                        'id': member[0],
                        'name': member[1],
                        'lat': member[2],
                        'lon': member[3],
                        'battery_pct': member[4],
                        'ts': DateTime.now().toUtc().toIso8601String(),
                        'accuracy_meters': 12
                      }
                  ];
                case '/family/places':
                  body = [];
                case '/config':
                  body = {'sms_configured': false};
                default:
                  body = {};
              }
              return http.Response(jsonEncode(body), 200,
                  headers: {'content-type': 'application/json'});
            }));
    File('../assets/google-play/tile-requests.txt')
        .writeAsStringSync(requestedTiles.join('\n'));
  });
}
