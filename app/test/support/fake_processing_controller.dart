import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart' show ServerProfile, ServerJoinInfo;
import 'package:openfamily/services/e2ee/lanes_service.dart' show LanesNotReady;
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart';

const String pA = '11111111-1111-4111-8111-111111111111';
const String pB = '22222222-2222-4222-8222-222222222222';
const String pC = '33333333-3333-4333-8333-333333333333';
const String fakeFp = 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12';

/// Screens talk to this; it records what they asked for and applies it to a
/// mutable snapshot, like the real controller would after the signed round trip.
class FakeProcessingController implements ProcessingController {
  FakeProcessingController(this.snap, {this.me = pA});
  ProcessingSnapshot snap;
  final String me;
  final List<String> calls = <String>[];
  Object? failWith;
  ServerProfile profile = ServerProfile.unknown;
  Object? loadFails;

  static ProcessingSnapshot snapshot({
    String me = pA,
    bool admin = true,
    bool assist = true,
    int optOut = E2ee.optOutAllowed,
    int defaultForNew = E2ee.linePhone,
    Map<String, int> lanes = const <String, int>{pA: E2ee.linePhone, pB: E2ee.linePhone},
    Set<String> unverified = const <String>{},
    bool legacy = false,
    bool legacyAccessOpen = false,
    bool isPrivate = true,
    bool serverKey = true,
    List<String> notReady = const <String>[],
    LaneStatus? status,
    Set<String> children = const <String>{},
    List<ProcessingViewer> viewers = const <ProcessingViewer>[],
    int undeliveredCount = 0,
    DateTime? optOutPendingSince,
  }) {
    final Map<String, String> names = <String, String>{pA: 'Alice', pB: 'Bob', pC: 'Carol'};
    final StoredPolicy pol = StoredPolicy(assist: assist, skGen: assist ? 1 : 0, defaultForNew: defaultForNew, memberOptOut: optOut);
    final bool meServer = lanes[me] == E2ee.lineServer;
    return ProcessingSnapshot(
      circleId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      isPrivate: isPrivate,
      policy: pol,
      status: status ??
          (meServer
              ? LaneStatus.serverAssisted
              : (assist && optOut == E2ee.optOutRequiredServer ? LaneStatus.consentRequired : LaneStatus.phoneOnly)),
      iAmAdmin: admin,
      legacy: legacy,
      legacyAccessOpen: legacyAccessOpen,
      viewers: viewers,
      undeliveredCount: undeliveredCount,
      undeliveredCode: undeliveredCount > 0 ? 'required_server' : '',
      optOutPendingSince: optOutPendingSince,
      notReady: notReady,
      serverKeyShort: serverKey ? 'ab12 cd34' : null,
      serverKeyDigits: serverKey ? '11111 22222 33333' : null,
      serverKeyFingerprint: serverKey ? fakeFp : null,
      members: <ProcessingMember>[
        for (final MapEntry<String, int> e in lanes.entries)
          ProcessingMember(
              userId: e.key,
              name: names[e.key] ?? 'Member',
              lane: e.value,
              verified: !unverified.contains(e.key),
              isMe: e.key == me,
              isAdmin: e.key == pA,
              isChild: children.contains(e.key)),
      ],
    );
  }

  @override
  Future<ProcessingSnapshot> load(String circleId, {bool force = false}) async {
    calls.add('load');
    final Object? lf = loadFails;
    if (lf != null) throw lf;
    return snap;
  }

  void _maybeFail() {
    final Object? f = failWith;
    if (f != null) throw f;
  }

  @override
  Future<void> setMyLane(String circleId, int lane, {String? confirmServerFingerprintHex, bool deleteCopies = false}) async {
    _maybeFail();
    calls.add('lane:${E2ee.lineName(lane)}:fp=${confirmServerFingerprintHex ?? '-'}:del=$deleteCopies');
  }

  @override
  Future<void> setPolicy(String circleId, {required bool assist, required int defaultForNew, required int memberOptOut}) async {
    _maybeFail();
    if (snap.notReady.isNotEmpty && assist && !snap.assistOn) throw LanesNotReady(snap.notReady);
    calls.add('policy:$assist:${E2ee.lineName(defaultForNew)}:${E2ee.optOutName(memberOptOut)}');
  }

  @override
  Future<int> deleteCopies(String circleId, {required bool wholeCircle}) async {
    calls.add('delete:${wholeCircle ? 'circle' : 'mine'}');
    return 3;
  }

  @override
  Future<void> upgradeLegacy(String circleId) async {
    _maybeFail();
    calls.add('upgrade');
    snap = FakeProcessingController.snapshot(me: me, admin: snap.iAmAdmin, legacy: false);
  }

  @override
  Future<void> endLegacyAccess(String circleId) async => calls.add('end-legacy');

  @override
  Future<ServerProfile> serverProfile() async => profile;

  /// What GET /e2ee/server-join answers; tests set it to simulate "your server wants to join".
  ServerJoinInfo join = ServerJoinInfo.none;

  /// Approving makes the snapshot show an approved server key (as the real server does after it pinned itself).
  @override
  Future<ServerJoinInfo> serverJoin() async => join;

  @override
  Future<void> approveServerJoin() async {
    _maybeFail();
    calls.add('approve-server-join');
    join = ServerJoinInfo.none;
    onServerApproved?.call();
  }

  void Function()? onServerApproved;
}
