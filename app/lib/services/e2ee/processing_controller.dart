import '../api_client.dart' show ApiException, SessionExpiredException;
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'e2ee_service.dart' show localKeyProblemOf;
import 'lanes_service.dart';
import 'lanes_store.dart';
import 'private_channel.dart' show SealedQueue;
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
    this.isChild = false,
  });
  final String userId;
  final String name;

  /// [E2ee.linePhone] / [E2ee.lineServer].
  final int lane;

  /// A signed pref backs the lane. False means "no choice made yet" (phone by default).
  final bool verified;
  final bool isMe;
  final bool isAdmin;

  /// A child account: the pairing-time choice stands and `required_server` applies to it like to everybody.
  final bool isChild;

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
    this.viewers = const <ProcessingViewer>[],
    this.undeliveredCount = 0,
    this.undeliveredCode = '',
    this.optOutPendingSince,
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

  /// Set when the processing records could not be checked right now. Everything else in the snapshot is then only what
  /// this phone remembers: a screen must not present it as the current state.
  final String? problem;
  bool get unconfirmed => problem != null;

  /// Web viewers and bridges that members approved for this circle (any member can see this).
  final List<ProcessingViewer> viewers;

  /// Items of this phone the relay refused for good (e.g. `required_server`), so the user is told instead of silence.
  final int undeliveredCount;
  final String undeliveredCode;

  /// Set while this member's opt-out has not been accepted by the server yet.
  final DateTime? optOutPendingSince;

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

class ProcessingViewer {
  const ProcessingViewer(this.ownerName, this.kind);
  final String ownerName;

  /// 'web' | 'service'
  final String kind;
}

abstract class ProcessingController {
  Future<ProcessingSnapshot> load(String circleId, {bool force = false});

  /// This member's OWN choice. [confirmServerFingerprintHex] is needed for the server lane.
  /// [deleteCopies]: also ask the server to delete this member's copies (phone lane).
  Future<void> setMyLane(String circleId, int lane, {String? confirmServerFingerprintHex, bool deleteCopies = false});

  /// Circle admin only.
  Future<void> setPolicy(String circleId, {required bool assist, required int defaultForNew, required int memberOptOut});

  /// Circle admin only: the one "Require server processing" switch. On: server processing is on and every member's phone
  /// signs its own server choice by itself (no prompt). Off: server processing stays on and members choose again.
  Future<void> setRequireServer(String circleId, bool on);

  Future<int> deleteCopies(String circleId, {required bool wholeCircle});

  Future<void> upgradeLegacy(String circleId);
  Future<void> endLegacyAccess(String circleId);

  /// The server's deployment profile and pinned key; never throws for an older server ([ServerProfile.unknown]).
  Future<ServerProfile> serverProfile();

  /// "Your server wants to join" (the built-in server device). Never throws; older servers answer none.
  Future<ServerJoinInfo> serverJoin();

  /// Server administrator's phone: approves the server's key after the code was compared.
  Future<void> approveServerJoin();
}

class LanesProcessingController implements ProcessingController {
  LanesProcessingController(this.lanes);
  final LanesService lanes;

  /// The controller of the running app.
  static ProcessingController? testInstance;
  static ProcessingController get instance => testInstance ?? LanesProcessingController(PrivateRuntime.instance.lanesService);

  /// What the screen shows when the processing records could not be checked (anything that is not a transport
  /// failure or this phone's own key): the circle and its members from the server, the lane facts this phone verified
  /// earlier, and a plain [ProcessingSnapshot.problem]. Never a dead end: positions keep going to the family.
  static const String checkProblem = "Could not confirm this circle's server processing settings right now. Your phone keeps "
      'sending your position to the family, encrypted. Pull down to try again.';

  Future<ProcessingSnapshot> _degraded(String circleId, String me) async {
    final CircleE2eeState st = await lanes.api.circleState(circleId); // a transport failure here is the real error
    final Map<String, CircleE2eeMember> byId = <String, CircleE2eeMember>{for (final CircleE2eeMember m in st.members) m.userId: m};
    final Map<String, MemberLaneView> known = <String, MemberLaneView>{};
    try {
      for (final MemberLaneView v in await lanes.members(circleId)) {
        known[v.userId] = v;
      }
    } catch (_) {}
    StoredPolicy policy = StoredPolicy.off;
    LaneStatus status = LaneStatus.phoneOnly;
    try {
      policy = await lanes.store.policy(circleId);
      status = await lanes.store.status(circleId);
    } catch (_) {}
    return ProcessingSnapshot(
      circleId: circleId,
      isPrivate: st.isPrivate,
      policy: policy,
      status: status,
      iAmAdmin: byId[me]?.role == 'admin',
      problem: checkProblem,
      members: <ProcessingMember>[
        for (final CircleE2eeMember m in st.members)
          ProcessingMember(
            userId: m.userId,
            name: m.name.isEmpty ? 'Member' : m.name,
            lane: known[m.userId]?.lane ?? E2ee.linePhone,
            verified: known[m.userId]?.verified ?? false,
            isMe: m.userId == me,
            isAdmin: m.role == 'admin',
            isChild: m.role == 'child',
          )
      ],
    );
  }

  @override
  Future<ProcessingSnapshot> load(String circleId, {bool force = false}) async {
    final String me = (await lanes.service.identity())?.userId ?? '';
    // Repairs after a key reset or a replaced server key, without a tap (re-signs this member's own choice, the admin's
    // policy, re-attaches the server key). Best effort: whatever it cannot do yet is shown below.
    try {
      await lanes.selfHeal(circleId);
    } catch (_) {}
    try {
      await lanes.retryPendingOptOut(circleId);
    } catch (_) {}
    final CircleLanes cl;
    try {
      cl = await lanes.refresh(circleId, force: force);
    } on ApiException {
      rethrow;
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (localKeyProblemOf(e) != null) rethrow; // this phone's own key: the screen says so in plain words
      return _degraded(circleId, me);
    }
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
          isChild: byId[v.userId]?.role == 'child',
        )
    ];
    final DeviceKey? sk = cl.serverKey;
    final SealedQueue q = SealedQueue(kv: lanes.kv);
    if (members.any((ProcessingMember m) => m.isMe && m.serverAssisted)) await q.clearUndelivered(circleId);
    final und = await q.undelivered(circleId);
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
          // An app that predates `required_server` cannot sign its own lane: it needs the new app, not a wait.
          if (m.devices.any((DeviceKey d) =>
              d.kind == 'device' &&
              d.approved == true &&
              d.isActive &&
              (!d.supportsLanes || (cl.policy.assist && cl.policy.memberOptOut == E2ee.optOutRequiredServer && !d.supportsRequiredServer))))
            (m.name.isEmpty ? m.userId : m.name)
      ],
      problem: cl.problem,
      viewers: <ProcessingViewer>[
        for (final CircleE2eeMember m in st.members)
          for (final DeviceKey d in m.devices)
            if ((d.kind == 'web' || d.kind == 'service') && d.isActive && d.approved == true) ProcessingViewer(m.name.isEmpty ? 'A member' : m.name, d.kind)
      ],
      undeliveredCount: und?.count ?? 0,
      undeliveredCode: und?.code ?? '',
      optOutPendingSince: await lanes.store.pendingSince(circleId),
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
  Future<void> setRequireServer(String circleId, bool on) => lanes.publishPolicy(circleId,
      serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: on ? E2ee.optOutRequiredServer : E2ee.optOutAllowed);

  @override
  Future<int> deleteCopies(String circleId, {required bool wholeCircle}) => lanes.api.purgeServerCopies(circleId, wholeCircle: wholeCircle);

  @override
  Future<void> upgradeLegacy(String circleId) => lanes.upgradeLegacy(circleId);

  @override
  Future<void> endLegacyAccess(String circleId) => lanes.endLegacyServerAccess(circleId);

  @override
  Future<ServerProfile> serverProfile() async {
    try {
      return await lanes.api.serverProfile();
    } catch (_) {
      return ServerProfile.unknown;
    }
  }

  @override
  Future<ServerJoinInfo> serverJoin() async {
    try {
      return await lanes.api.serverJoin();
    } catch (_) {
      return ServerJoinInfo.none;
    }
  }

  @override
  Future<void> approveServerJoin() => lanes.service.approveServerJoin();
}
