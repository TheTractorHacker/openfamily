import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'lanes_service.dart';
import 'lanes_store.dart';
import 'private_runtime.dart';

// The one seam between the processing screens and `LanesService`. Screens only
// read a [ProcessingSnapshot] (everything in it was VERIFIED by this phone, see
// lanes_service.dart) and call the few actions below. Tests use a fake.

/// One member as the screens show them.
class ProcessingMember {
  const ProcessingMember({
    required this.userId,
    required this.name,
    required this.lane,
    required this.verified,
    required this.isMe,
    required this.isAdmin,
  });
  final String userId;
  final String name;

  /// [E2ee.linePhone] / [E2ee.lineServer].
  final int lane;

  /// A signed pref backs the lane. False means "no choice made yet" (phone by default).
  final bool verified;
  final bool isMe;
  final bool isAdmin;

  bool get serverAssisted => lane == E2ee.lineServer;
}

/// The verified situation of one circle, from the point of view of this phone.
class ProcessingSnapshot {
  const ProcessingSnapshot({
    required this.circleId,
    required this.isPrivate,
    required this.policy,
    required this.status,
    required this.members,
    required this.iAmAdmin,
    this.legacy = false,
    this.legacyAccessOpen = false,
    this.serverKeyShort,
    this.serverKeyDigits,
    this.serverKeyFingerprint,
    this.notReady = const <String>[],
    this.problem,
  });
  final String circleId;
  final bool isPrivate;
  final StoredPolicy policy;
  final LaneStatus status;
  final List<ProcessingMember> members;
  final bool iAmAdmin;

  /// Still in the old trusted-server mode (the server key holds the circle key of some epochs).
  final bool legacy;

  /// An upgraded circle whose server key still opens the old data (an admin can end that).
  final bool legacyAccessOpen;

  /// The pinned server key, null when the circle has no valid one.
  final String? serverKeyShort;
  final String? serverKeyDigits;
  final String? serverKeyFingerprint;

  /// Members whose app cannot yet read the server line (admin cannot turn on).
  final List<String> notReady;
  final String? problem;

  ProcessingMember? get me {
    for (final ProcessingMember m in members) {
      if (m.isMe) return m;
    }
    return null;
  }

  int get serverCount => members.where((ProcessingMember m) => m.serverAssisted).length;
  int get phoneCount => members.length - serverCount;
  bool get assistOn => policy.assist;
  bool get required => policy.assist && policy.memberOptOut == E2ee.optOutRequiredServer;
  bool get hasServerKey => serverKeyFingerprint != null;
}

abstract class ProcessingController {
  Future<ProcessingSnapshot> load(String circleId, {bool force = false});

  /// This member's OWN choice. [confirmServerFingerprintHex] is needed for the server lane.
  /// [deleteCopies]: also ask the server to delete this member's copies (phone lane).
  Future<void> setMyLane(String circleId, int lane, {String? confirmServerFingerprintHex, bool deleteCopies = false});

  /// Circle admin only.
  Future<void> setPolicy(String circleId, {required bool assist, required int defaultForNew, required int memberOptOut});

  Future<int> deleteCopies(String circleId, {required bool wholeCircle});

  Future<void> upgradeLegacy(String circleId);
  Future<void> endLegacyAccess(String circleId);
}

class LanesProcessingController implements ProcessingController {
  LanesProcessingController(this.lanes);
  final LanesService lanes;

  /// The controller of the running app.
  static ProcessingController? testInstance;
  static ProcessingController get instance => testInstance ?? LanesProcessingController(PrivateRuntime.instance.lanesService);

  @override
  Future<ProcessingSnapshot> load(String circleId, {bool force = false}) async {
    final String me = (await lanes.service.identity())?.userId ?? '';
    final CircleLanes cl = await lanes.refresh(circleId, force: force);
    final CircleE2eeState? st = cl.state;
    if (st == null) {
      return ProcessingSnapshot(
          circleId: circleId, isPrivate: false, policy: cl.policy, status: cl.status, members: const <ProcessingMember>[], iAmAdmin: false, problem: cl.problem);
    }
    final Map<String, CircleE2eeMember> byId = <String, CircleE2eeMember>{for (final CircleE2eeMember m in st.members) m.userId: m};
    final List<ProcessingMember> members = <ProcessingMember>[
      for (final MemberLaneView v in cl.members)
        ProcessingMember(
          userId: v.userId,
          name: (byId[v.userId]?.name ?? '').isEmpty ? 'Member' : byId[v.userId]!.name,
          lane: v.lane,
          verified: v.verified,
          isMe: v.userId == me,
          isAdmin: byId[v.userId]?.role == 'admin',
        )
    ];
    final DeviceKey? sk = cl.serverKey;
    return ProcessingSnapshot(
      circleId: circleId,
      isPrivate: st.isPrivate,
      policy: cl.policy,
      status: cl.status,
      members: members,
      iAmAdmin: byId[me]?.role == 'admin',
      legacy: cl.proc?.legacy ?? false,
      legacyAccessOpen: cl.proc?.legacyAccessOpen ?? false,
      serverKeyShort: sk?.short,
      serverKeyDigits: sk?.digits,
      serverKeyFingerprint: sk?.fingerprint,
      notReady: <String>[
        for (final CircleE2eeMember m in st.members)
          if (m.devices.any((DeviceKey d) => d.kind == 'device' && d.approved == true && d.isActive && !d.supportsLanes)) (m.name.isEmpty ? m.userId : m.name)
      ],
      problem: cl.problem,
    );
  }

  @override
  Future<void> setMyLane(String circleId, int lane, {String? confirmServerFingerprintHex, bool deleteCopies = false}) async {
    await lanes.setLane(circleId, lane, confirmServerFingerprintHex: confirmServerFingerprintHex);
    if (deleteCopies && lane == E2ee.linePhone) {
      await lanes.api.purgeServerCopies(circleId);
    }
  }

  @override
  Future<void> setPolicy(String circleId, {required bool assist, required int defaultForNew, required int memberOptOut}) =>
      lanes.publishPolicy(circleId, serverAssist: assist, defaultForNew: defaultForNew, memberOptOut: memberOptOut);

  @override
  Future<int> deleteCopies(String circleId, {required bool wholeCircle}) => lanes.api.purgeServerCopies(circleId, wholeCircle: wholeCircle);

  @override
  Future<void> upgradeLegacy(String circleId) => lanes.upgradeLegacy(circleId);

  @override
  Future<void> endLegacyAccess(String circleId) => lanes.endLegacyServerAccess(circleId);
}
