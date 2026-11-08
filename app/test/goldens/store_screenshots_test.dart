import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/check_in_screen.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/screens/people_screen.dart';
import 'package:openfamily/screens/places_screen.dart';
import 'package:openfamily/screens/processing_screen.dart';
import 'package:openfamily/screens/sos_screen.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/alert_screens_test.dart' show FakeDialer;
import '../support/fake_processing_controller.dart';
import 'docs_screenshots_test.dart'
    show
        docsChat,
        docsCircleName,
        docsCircles,
        docsFamily,
        docsPlace,
        docsProcessing,
        loadDocsFonts;

/// Renders the real app screens (widget tree + the fictional "Rivera Family"
/// fixtures of the user documentation, no phone) at the pixel size of each
/// store screenshot slot, WITHOUT the caption. scripts/store-assets/compose.py
/// then puts them on a branded background with a caption and writes the final
/// files. Skipped unless `STORE_ASSETS=1`; output goes to `$STORE_RAW`
/// (default `../dist/store-assets/raw`). See scripts/store-assets.sh and
/// docs/release/STORE_ASSETS.md.
///
/// These are drawings of the widget tree with the Roboto font and no map
/// tiles, not captures from a device. Stores require truthful screenshots:
/// recapture the final set on a device (docs/release/STORE_ASSETS.md).
final bool _on = Platform.environment['STORE_ASSETS'] == '1';
final String _out =
    Platform.environment['STORE_RAW'] ?? '../dist/store-assets/raw';

/// A store slot: final image size and the logical width the screen is laid
/// out at (decides phone, tablet or foldable layout).
class _Slot {
  const _Slot(this.name, this.w, this.h, this.logicalWidth);
  final String name;
  final int w;
  final int h;
  final double logicalWidth;

  int get margin => (w * 0.06).round();
  int get captionHeight => (h * 0.16).round();
  int get innerW => w - 2 * margin;
  int get innerH => h - captionHeight - margin;
}

const List<_Slot> _slots = <_Slot>[
  _Slot('play-phone', 1080, 1920, 412),
  _Slot('play-tablet7', 1200, 1920, 600),
  _Slot('play-tablet10', 1600, 2560, 800),
  _Slot('play-foldable', 1840, 2208, 700),
  _Slot('ios-iphone-6.9', 1320, 2868, 440),
  _Slot('ios-iphone-6.5', 1284, 2778, 428),
  _Slot('ios-ipad-13', 2064, 2752, 1032),
];

class _Shot {
  const _Shot(this.name, this.caption, this.build);
  final String name;
  final String caption;
  final Widget Function() build;
}

final GlobalKey _boundary = GlobalKey();

Widget _frame(Widget home) {
  final ThemeData theme = buildLightTheme();
  return RepaintBoundary(
    key: _boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
        listTileTheme: theme.listTileTheme.copyWith(
          titleTextStyle:
              theme.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
          subtitleTextStyle: theme.listTileTheme.subtitleTextStyle
              ?.copyWith(fontFamily: 'Roboto'),
        ),
      ),
      builder: (BuildContext c, Widget? child) => DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: 'Roboto'),
        child: child!,
      ),
      home: home,
    ),
  );
}

Place _place(String id, String name, double lat, String type, String address) =>
    docsPlace(id, name, lat, type, address);

List<_Shot> _shots() => <_Shot>[
      _Shot(
        'people',
        'See your whole circle at a glance',
        () => PeopleScreen(
          circleName: docsCircleName,
          members: ValueNotifier<List<Member>>(docsFamily),
        ),
      ),
      _Shot(
        'places',
        'Know when they arrive and leave',
        () => PlacesScreen(
          loader: () async => PlacesSnapshot(places: <Place>[
            _place('p1', 'Home', 37.78, 'home', '12 Oak Street'),
            _place('p2', 'Maple Elementary', 37.79, 'school',
                '400 Maple Avenue'),
            _place('p3', 'Grandma', 37.80, 'custom', '8 Pine Lane'),
          ]),
        ),
      ),
      _Shot('chat', 'Private chat with your circle', docsChat),
      _Shot(
        'sos',
        'One tap tells your circle you need help',
        () => SosScreen(smsConfigured: true, dialer: FakeDialer()),
      ),
      _Shot(
        'check-in',
        'Let them know you got there safe',
        () => CheckInScreen(
          loadPlaces: () async => <Place>[
            _place('a', 'Home', 0.001, 'home', '12 Oak Street'),
            _place('b', 'Maple Elementary', 0.004, 'school',
                '400 Maple Avenue'),
          ],
          loadPosition: () async => const LatLng(0, 0),
          send: (Map<String, dynamic> b) async => null,
        ),
      ),
      _Shot(
        'circles',
        'Several circles, one app, your own server',
        () => CirclesScreen(service: docsCircles()),
      ),
      _Shot(
        'private',
        'Private circles are encrypted on your phone',
        () => ProcessingScreen(
          circle: const Circle(
            id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            name: docsCircleName,
            role: 'admin',
            sharingEnabled: true,
            memberCount: 4,
            e2eeMode: 'private',
          ),
          controller: FakeProcessingController(docsProcessing()),
        ),
      ),
    ];

void main() {
  setUpAll(loadDocsFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sos_intro_seen': true,
    });
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  if (_on) {
    // Hand the fonts and the caption text to the compositor.
    final Directory dir = Directory(_out)..createSync(recursive: true);
    final String? root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final File bold =
          File('$root/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf');
      if (bold.existsSync()) bold.copySync('${dir.path}/Roboto-Bold.ttf');
    }
    final List<_Shot> shots = _shots();
    File('${dir.path}/manifest.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object>{
        'slots': <Map<String, Object>>[
          for (final _Slot s in _slots)
            <String, Object>{
              'name': s.name,
              'w': s.w,
              'h': s.h,
              'margin': s.margin,
              'caption_height': s.captionHeight,
            },
        ],
        'shots': <Map<String, String>>[
          for (final _Shot s in shots)
            <String, String>{'name': s.name, 'caption': s.caption},
        ],
      }),
    );
  }

  for (final _Slot slot in _slots) {
    for (final _Shot shot in _shots()) {
      testWidgets('store screenshot ${slot.name} ${shot.name}',
          (WidgetTester t) async {
        final double dpr = slot.innerW / slot.logicalWidth;
        t.view.physicalSize = Size(slot.innerW.toDouble(), slot.innerH.toDouble());
        t.view.devicePixelRatio = dpr;
        addTearDown(t.view.reset);
        await t.pumpWidget(_frame(shot.build()));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await t.pumpAndSettle();
        final RenderRepaintBoundary b = _boundary.currentContext!
            .findRenderObject()! as RenderRepaintBoundary;
        final List<int> bytes = (await t.runAsync(() async {
          final ui.Image img = await b.toImage(pixelRatio: dpr);
          final ByteData? d =
              await img.toByteData(format: ui.ImageByteFormat.png);
          return d!.buffer.asUint8List().toList();
        }))!;
        final Directory d = Directory(_out)..createSync(recursive: true);
        File('${d.path}/${slot.name}__${shot.name}.png')
            .writeAsBytesSync(bytes);
      }, skip: !_on);
    }
  }
}
