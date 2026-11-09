import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:openfamily/models/chat_message.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/screens/chat_screen.dart';
import 'package:openfamily/screens/check_in_screen.dart';
import 'package:openfamily/screens/circle_detail_screen.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/screens/create_circle_screen.dart';
import 'package:openfamily/screens/create_or_join_circle_screen.dart';
import 'package:openfamily/screens/encryption_keys_screen.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/screens/invite_screen.dart';
import 'package:openfamily/screens/login_screen.dart';
import 'package:openfamily/screens/people_screen.dart';
import 'package:openfamily/screens/permissions_screen.dart';
import 'package:openfamily/screens/places_screen.dart';
import 'package:openfamily/screens/processing_policy_screen.dart';
import 'package:openfamily/screens/processing_screen.dart';
import 'package:openfamily/screens/security_screen.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/screens/sos_screen.dart';
import 'package:openfamily/screens/welcome_screen.dart';
import 'package:openfamily/services/app_compat.dart';
import 'package:openfamily/services/attention_service.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/delivery_status.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart'
    show ProcessingMember, ProcessingSnapshot;
import 'package:openfamily/services/offline/server_reachability.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/attention_center.dart';
import 'package:openfamily/widgets/server_prompts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/alert_screens_test.dart' show FakeDialer;
import '../screens/circles_screens_test.dart' show FakeCircleService;
import '../support/fake_e2ee_server.dart';
import '../support/fake_processing_controller.dart';
import '../support/fake_security_api.dart';
import '../support/trip_report_fixtures.dart';

/// The fixtures below (docsCircles, docsFamily, docsChat, ...) are shared with
/// store_screenshots_test.dart, which renders the store listing images.
///
/// Renders real app screens (from the widget tree, with fake data) to PNGs for
/// the user documentation. Skipped unless `DOCS_SCREENSHOTS=1`. Output goes to
/// `$DOCS_OUT` (default `../docs/images/app`). See scripts/docs-screenshots-app.sh.
final bool _on = Platform.environment['DOCS_SCREENSHOTS'] == '1';
final String _out = Platform.environment['DOCS_OUT'] ?? '../docs/images/app';

Future<void> loadDocsFonts() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final String dir = '$root/bin/cache/artifacts/material_fonts';
  final FontLoader roboto = FontLoader('Roboto');
  for (final String n in <String>['Roboto-Regular', 'Roboto-Bold']) {
    final File f = File('$dir/$n.ttf');
    if (f.existsSync()) {
      roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
  }
  await roboto.load();
  final File icons = File('$dir/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final FontLoader il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

final GlobalKey _shot = GlobalKey();

Widget _app(Widget home, ThemeData theme) => RepaintBoundary(
      key: _shot,
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

void _shoot(
  String name,
  Widget Function() screen, {
  bool dark = false,
  Future<void> Function()? before,
  Future<void> Function(WidgetTester)? after,
}) {
  final String file = dark ? '$name-dark' : name;
  testWidgets('docs screenshot $file', (WidgetTester t) async {
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    if (before != null) await t.runAsync(before);
    await t.pumpWidget(
      _app(screen(), dark ? buildDarkTheme() : buildLightTheme()),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pumpAndSettle();
    if (after != null) await after(t);
    final RenderRepaintBoundary b =
        _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final List<int> bytes = (await t.runAsync(() async {
      final ui.Image img = await b.toImage(pixelRatio: 2);
      final ByteData? d = await img.toByteData(format: ui.ImageByteFormat.png);
      return d!.buffer.asUint8List().toList();
    }))!;
    Directory(_out).createSync(recursive: true);
    File('$_out/$file.png').writeAsBytesSync(bytes);
  }, skip: !_on);
}

const String docsCircleName = 'The Rivera Family';

FakeCircleService docsCircles() => FakeCircleService()
  ..circles = <Circle>[
    const Circle(
      id: 'c1',
      name: docsCircleName,
      role: 'admin',
      sharingEnabled: true,
      memberCount: 4,
      isPrimary: true,
    ),
    const Circle(
      id: 'c2',
      name: 'Soccer carpool',
      role: 'member',
      sharingEnabled: true,
      memberCount: 5,
    ),
    const Circle(
      id: 'c3',
      name: 'Grandparents',
      role: 'member',
      sharingEnabled: false,
      memberCount: 3,
    ),
  ]
  ..members = <CircleMember>[
    const CircleMember(userId: 'me', name: 'Maria', role: 'admin', sharingEnabled: true),
    const CircleMember(userId: 'u2', name: 'Carlos', role: 'admin', sharingEnabled: true),
    const CircleMember(userId: 'u3', name: 'Sofia', role: 'member', sharingEnabled: true),
    const CircleMember(userId: 'u4', name: 'Mateo', role: 'member', sharingEnabled: false),
  ];

Member docsMember(String id, String name, Color c, MemberStatus s, int battery,
        String address,
        {MovementType movement = MovementType.none}) =>
    Member(
      id: id,
      name: name,
      // Fictional point in the open sea; never a real home.
      position: const LatLng(10, -30),
      movement: movement,
      lastSeen: DateTime.now().toUtc(),
      status: s,
      batteryPercent: battery,
      address: address,
      avatarColor: c,
    );

final List<Member> docsFamily = <Member>[
  docsMember('me', 'Maria', const Color(0xFF7C3AED), MemberStatus.normal, 82,
      '12 Oak Street',
      movement: MovementType.home),
  docsMember('u2', 'Carlos', const Color(0xFF0284C7), MemberStatus.normal, 64,
      'Riverside Office Park',
      movement: MovementType.work),
  docsMember('u3', 'Sofia', const Color(0xFFDB2777), MemberStatus.normal, 91,
      'Maple Elementary'),
  docsMember('u4', 'Mateo', const Color(0xFF16A34A), MemberStatus.stopped, 0,
      'Last seen at 12 Oak Street'),
];

class _FakeChat implements ChatService {
  _FakeChat(this.history);
  final List<ChatMessage> history;

  @override
  Future<String> myUserId() async => 'me';
  @override
  Future<ChatPage> messages(String circleId,
          {int? before, int? after, int limit = 50}) async =>
      ChatPage(history, null, const <ChatReader>[]);
  @override
  Future<void> markRead(String circleId, {int? seq}) async {}
  @override
  Future<Map<String, int>> unread() async => <String, int>{'c1': 0};
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

List<ChatMessage> _conversation() {
  final List<(String, String, String)> lines = <(String, String, String)>[
    ('u3', 'Sofia', 'Practice is over, can someone pick me up?'),
    ('u2', 'Carlos', 'I am still at the office, about 30 minutes away.'),
    ('me', 'Maria', 'I can go! Leaving the house now.'),
    ('u3', 'Sofia', 'Thanks Mom! I will wait by the main gate.'),
    ('me', 'Maria', 'Perfect. Mateo, do you want pasta tonight?'),
    ('u4', 'Mateo', 'Yes please! Can we have garlic bread too?'),
    ('u2', 'Carlos', 'I will pick up the bread on my way home.'),
  ];
  final List<ChatMessage> out = <ChatMessage>[];
  for (int i = 0; i < lines.length; i++) {
    out.add(ChatMessage(
      id: 'm$i',
      seq: i + 1,
      circleId: 'c1',
      senderId: lines[i].$1,
      senderName: lines[i].$2,
      body: lines[i].$3,
      createdAt: DateTime(2026, 10, 26, 17, 5 + i * 2),
    ));
  }
  // Newest first, as the service returns them.
  return out.reversed.toList();
}

Widget docsChat() => ChatScreen(
      circleId: 'c1',
      circleName: docsCircleName,
      service: _FakeChat(_conversation()),
      incoming: const Stream<ChatMessage>.empty(),
      edits: const Stream<ChatMessage>.empty(),
      deletes: const Stream<(String, String)>.empty(),
      reconnects: const Stream<void>.empty(),
    );

Place docsPlace(String id, String name, double lat, String type, String address) =>
    Place(
      id: id,
      name: name,
      icon: Place.iconForType(type),
      address: address,
      position: LatLng(lat, 0),
      radiusMeters: 100,
      type: type,
    );

Widget _drivingReport() => FamilyDrivingReportScreen(
      members: ValueNotifier<List<Member>>(<Member>[
        docsMember('u1', 'Maria', const Color(0xFF7C3AED), MemberStatus.normal, 80, ''),
        docsMember('u2', 'Carlos', const Color(0xFF0284C7), MemberStatus.normal, 80, ''),
      ]),
      userId: ValueNotifier<String?>(null),
      api: FakeTripReportApi(result: reportJson(twoMembers: true, speeding: 2)),
      clock: () => DateTime(2026, 10, 26, 9),
    );

/// Four fictional members; Maria (you) lets the server help, the rest stay phone-only.
ProcessingSnapshot docsProcessing() {
  final ProcessingSnapshot b = FakeProcessingController.snapshot(
    lanes: <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone},
  );
  ProcessingMember m(String id, String name, int lane, bool admin, bool me) =>
      ProcessingMember(
        userId: id,
        name: name,
        lane: lane,
        verified: true,
        isMe: me,
        isAdmin: admin,
      );
  return ProcessingSnapshot(
    circleId: b.circleId,
    isPrivate: b.isPrivate,
    policy: b.policy,
    status: b.status,
    iAmAdmin: true,
    serverKeyShort: b.serverKeyShort,
    serverKeyDigits: b.serverKeyDigits,
    serverKeyFingerprint: b.serverKeyFingerprint,
    members: <ProcessingMember>[
      m(pA, 'Maria', E2ee.lineServer, true, true),
      m(pB, 'Carlos', E2ee.linePhone, false, false),
      m(pC, 'Sofia', E2ee.linePhone, false, false),
      m('44444444-4444-4444-8444-444444444444', 'Mateo', E2ee.linePhone, false, false),
    ],
  );
}

// Encryption keys: a real E2eeService against the in-memory fake server, so
// the screen shows real fingerprints and safety numbers (all made up).
const String _kMaria = '11111111-1111-4111-8111-111111111111';
const String _kCarlos = '22222222-2222-4222-8222-222222222222';
const String _kSofia = '33333333-3333-4333-8333-333333333333';
const String _kCircle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

class _StrongBoxVault extends MemoryVault {
  @override
  Future<KeystoreStatus> status() async =>
      const KeystoreStatus(level: KeystoreLevel.strongBox);
}

class _KeysCircles implements CircleService {
  @override
  Future<String> myUserId() async => _kMaria;
  @override
  Future<List<CircleMember>> listMembers(String id) async => const <CircleMember>[
        CircleMember(userId: _kMaria, name: 'Maria', role: 'admin', sharingEnabled: true),
        CircleMember(userId: _kCarlos, name: 'Carlos', role: 'member', sharingEnabled: true),
        CircleMember(userId: _kSofia, name: 'Sofia', role: 'member', sharingEnabled: true),
      ];
  @override
  Future<List<CircleInvite>> listInvites(String id) async => <CircleInvite>[];
  @override
  Future<List<Circle>> listCircles() async => const <Circle>[
        Circle(id: _kCircle, name: docsCircleName, role: 'admin', sharingEnabled: true, memberCount: 3, e2eeMode: 'private'),
      ];
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

E2eeService? _keysService;

Future<void> _setUpKeys() async {
  final FakeE2eeServer server = FakeE2eeServer()
    ..names.addAll(<String, String>{_kMaria: 'Maria', _kCarlos: 'Carlos', _kSofia: 'Sofia'});
  server.circle(_kCircle, members: <String>[_kMaria, _kCarlos, _kSofia], admin: _kMaria);
  E2eeService svc(String user, E2eeVault vault) => E2eeService(
        api: server.client(user),
        vault: vault,
        trust: TrustStore(MemoryTrustKv()),
        userIdProvider: () async => user,
      );
  final E2eeService maria = svc(_kMaria, _StrongBoxVault());
  await maria.registerThisDevice();
  await svc(_kCarlos, MemoryVault()).registerThisDevice();
  await svc(_kSofia, MemoryVault()).registerThisDevice();
  await maria.enableCircle(_kCircle);
  _keysService = maria;
}

Future<void> _settleAsync(WidgetTester t) async {
  for (int i = 0; i < 3; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

// Attention icon: an AppBar with the icon, then the sheet opened by a tap.
AttentionService? _attention;

Widget _attentionHost() {
  const Circle rivera = Circle(
    id: 'c1',
    name: docsCircleName,
    role: 'member',
    sharingEnabled: true,
    memberCount: 4,
    isPrimary: true,
    e2eeMode: 'private',
    serverAssist: true,
  );
  AppCompat.debugReset();
  DeliveryHints.clear();
  ServerChoiceStore.debugReset();
  _attention?.dispose();
  final AttentionService svc =
      AttentionService(reachability: ServerReachability(probe: () async => true));
  _attention = svc;
  AppCompat.state.value = const CompatState(status: CompatStatus.recommended);
  DeliveryHints.circleById[rivera.id] = rivera;
  DeliveryHints.put(CircleDelivery(
    circleId: rivera.id,
    summary: 'ok',
    members: const <MemberDelivery>[
      MemberDelivery(userId: 'me', name: 'Maria', you: true, reason: DeliveryReason.ok),
    ],
    at: DateTime.now(),
  ));
  return Scaffold(
    appBar: AppBar(
      title: const Text('Safety'),
      actions: <Widget>[AttentionButton(service: svc)],
    ),
    body: const SizedBox.expand(),
  );
}

void main() {
  setUpAll(loadDocsFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sos_intro_seen': true,
    });
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  _shoot('welcome', () => const WelcomeScreen());
  _shoot('login', () => const LoginScreen());
  _shoot('create-or-join', () => const CreateOrJoinCircleScreen());
  _shoot('create-circle', () => const CreateCircleScreen());
  _shoot('invite', () => const InviteScreen(circleName: docsCircleName, step: 5));
  _shoot('permissions', () => const PermissionsScreen());
  _shoot('circles', () => CirclesScreen(service: docsCircles()));
  _shoot('circles', () => CirclesScreen(service: docsCircles()), dark: true);
  _shoot(
    'circle-detail',
    () => CircleDetailScreen(
      circle: docsCircles().circles.first,
      service: docsCircles(),
    ),
  );
  _shoot(
    'people',
    () => PeopleScreen(
      circleName: docsCircleName,
      members: ValueNotifier<List<Member>>(docsFamily),
    ),
  );
  _shoot('settings', () => const SettingsScreen());
  _shoot(
    'security',
    () => SecurityScreen(
      api: FakeSecurityApi(
        account: const AccountInfo(
          id: 'me',
          email: 'maria@example.com',
          role: 'admin',
          totpEnabled: true,
        ),
      ),
    ),
  );
  _shoot(
    'processing',
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
  );
  _shoot(
    'processing-policy',
    () => ProcessingPolicyScreen(
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
  );
  _shoot('sos', () => SosScreen(smsConfigured: true, dialer: FakeDialer()));
  _shoot(
    'check-in',
    () => CheckInScreen(
      loadPlaces: () async => <Place>[
        docsPlace('a', 'Home', 0.001, 'home', '12 Oak Street'),
        docsPlace('b', 'Maple Elementary', 0.004, 'school', '400 Maple Avenue'),
      ],
      loadPosition: () async => const LatLng(0, 0),
      send: (Map<String, dynamic> b) async => null,
    ),
  );
  _shoot('chat', docsChat);
  _shoot('chat', docsChat, dark: true);
  _shoot(
    'places',
    () => PlacesScreen(
      loader: () async => PlacesSnapshot(places: <Place>[
        docsPlace('p1', 'Home', 37.78, 'home', '12 Oak Street'),
        docsPlace('p2', 'Maple Elementary', 37.79, 'school', '400 Maple Avenue'),
        docsPlace('p3', 'Grandma', 37.80, 'custom', '8 Pine Lane'),
      ]),
    ),
  );
  _shoot('driving-report', _drivingReport);
  _shoot(
    'encryption-keys',
    () => EncryptionKeysScreen(service: _keysService, circles: _KeysCircles()),
    before: _setUpKeys,
    after: _settleAsync,
  );
  _shoot(
    'attention',
    _attentionHost,
    after: (WidgetTester t) async {
      await t.tap(find.byKey(const Key('attention-button')));
      await t.pumpAndSettle();
    },
  );
}
