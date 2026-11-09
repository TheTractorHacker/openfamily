import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'lanes_service.dart' show LanesNotReady;
import 'processing_controller.dart';

// "Add server to this circle" in one guided sheet (docs/design/PRIVACY_PROCESSING.md
// section 21). This file is only the decision logic on top of the existing
// ProcessingController / LanesService: it adds no protocol and weakens no rule.
//
//   * An admin turning the server on signs the circle policy (assistance on) and
//     then their OWN lane. A member only ever signs their own lane.
//   * Nobody can add another member: everyone else is asked on their own phone.
//   * The fingerprint that is signed is the one this phone VERIFIED from the key
//     log (ProcessingSnapshot), never one sent in a single server answer.

enum AddServerState {
  /// A normal (non-private) circle: the server already stores positions there.
  notPrivate,

  /// The server has no usable key for this circle (not enrolled, or not approved here).
  serverMissing,

  /// The server's two answers about its key disagree. Never continue.
  keyConflict,

  /// This member's lane is already the server.
  alreadyAdded,

  /// The circle admin has not turned server processing on; a member cannot.
  needsAdmin,

  /// The old trusted-server mode: handled on the Encryption keys screen.
  legacy,

  /// An admin cannot switch it on yet: some member's app is too old.
  membersNeedUpdate,

  /// The built-in server device asked to join and this phone's owner is a server administrator:
  /// the same three steps approve the server's key first, then add it (one OK).
  approveServer,

  /// The server asked to join but only a server administrator can approve it.
  serverWaiting,

  /// Everything is in place.
  ready,
}

class AddServerPlan {
  const AddServerPlan(this.state, this.snapshot, this.profile, {this.names = const <String>[], this.join = ServerJoinInfo.none});
  final AddServerState state;

  /// The pending join request of the built-in server device (waiting only).
  final ServerJoinInfo join;
  final ProcessingSnapshot snapshot;
  final ServerProfile profile;

  /// For [AddServerState.membersNeedUpdate]: the members to ask to update.
  final List<String> names;

  /// The four short groups the person compares ("AB12 CD34 EF56 7890"), from the verified key.
  String get words => state == AddServerState.approveServer ? join.short : (snapshot.serverKeyShort ?? '');

  /// The 12 groups of digits (the full code).
  String get digits => state == AddServerState.approveServer ? join.digits : (snapshot.serverKeyDigits ?? '');

  /// Whether OK also has to publish the circle policy first (circle admin, server not on yet).
  bool get adminTurnsOn => snapshot.iAmAdmin && !snapshot.assistOn;
}

class AddServerFlow {
  AddServerFlow(this.controller, {Duration? waitStep}) {
    if (waitStep != null) this.waitStep = waitStep;
  }
  final ProcessingController controller;

  /// Pause between checks while the server pins its key after being approved (tests use zero).
  Duration waitStep = const Duration(seconds: 1);

  /// Reads the verified situation. Throws what the controller throws (an older
  /// server without lanes, offline): the sheet turns that into plain text.
  Future<AddServerPlan> plan(String circleId) async {
    final ProcessingSnapshot s = await controller.load(circleId, force: true);
    final ServerProfile p = await controller.serverProfile();
    final ServerJoinInfo j = (!s.hasServerKey && s.isPrivate) ? await controller.serverJoin() : ServerJoinInfo.none;
    return AddServerPlan(_stateOf(s, p, j), s, p, names: s.notReady, join: j);
  }

  static AddServerState _stateOf(ProcessingSnapshot s, ServerProfile p, ServerJoinInfo j) {
    if (!s.isPrivate) return AddServerState.notPrivate;
    if (s.legacy) return AddServerState.legacy;
    final ProcessingMember? me = s.me;
    if (me != null && me.serverAssisted && s.assistOn) return AddServerState.alreadyAdded;
    if (!s.hasServerKey) {
      if (j.waiting && j.canApprove) return AddServerState.approveServer;
      if (j.waiting) return AddServerState.serverWaiting;
      return AddServerState.serverMissing;
    }
    // Two independent answers (the key log and the profile endpoint) must name the same key.
    final String? other = p.device?.fingerprint;
    if (other != null && other.toLowerCase() != s.serverKeyFingerprint!.toLowerCase()) return AddServerState.keyConflict;
    if (!s.assistOn && !s.iAmAdmin) return AddServerState.needsAdmin;
    if (!s.assistOn && s.notReady.isNotEmpty) return AddServerState.membersNeedUpdate;
    return AddServerState.ready;
  }

  /// Step 3. Returns the fresh snapshot. [LanesNotReady] and StateError carry plain messages for the sheet.
  /// [memberOptOut]: only used when this admin turns the server on (allowed, or required_server for a circle
  /// that must use the server, for example children's phones).
  Future<ProcessingSnapshot> confirm(String circleId, AddServerPlan plan, {int memberOptOut = E2ee.optOutAllowed}) async {
    if (plan.state == AddServerState.approveServer) {
      // The person compared the code: sign the server's key, wait until the server has pinned it, then continue as usual.
      await controller.approveServerJoin();
      AddServerPlan next = plan;
      for (int i = 0; i < 30; i++) {
        next = await this.plan(circleId);
        if (next.state != AddServerState.approveServer && next.state != AddServerState.serverWaiting && next.state != AddServerState.serverMissing) break;
        await Future<void>.delayed(waitStep);
      }
      if (next.state != AddServerState.ready) {
        throw StateError('The server is joining, but is not ready yet. Wait a moment and tap OK again.');
      }
      return confirm(circleId, next, memberOptOut: memberOptOut);
    }
    if (plan.state != AddServerState.ready) throw StateError('The server cannot be added yet.');
    ProcessingSnapshot s = plan.snapshot;
    if (plan.adminTurnsOn) {
      // Section 24: members are on the server by default. The circle default is the server lane whatever the
      // profile; each member's OWN phone then signs it (with a notice) unless a server administrator saved
      // "no auto-apply", and anyone can opt out. The admin can change the default on the policy screen. Never consent.
      await controller.setPolicy(circleId, assist: true, defaultForNew: E2ee.lineServer, memberOptOut: memberOptOut);
      s = await controller.load(circleId, force: true);
    }
    final String? fp = s.serverKeyFingerprint;
    if (fp == null) throw StateError('This circle has no approved Orbitly server key.');
    if (plan.snapshot.serverKeyFingerprint != fp) throw StateError('The server key changed while you were looking at it. Start again.');
    await controller.setMyLane(circleId, E2ee.lineServer, confirmServerFingerprintHex: fp);
    return controller.load(circleId, force: true);
  }

  /// Takes the server away for this member: their lane goes back to the phone and, if asked, the copies the
  /// server holds of their data are deleted (section 18.1).
  Future<void> remove(String circleId, {required bool deleteCopies}) =>
      controller.setMyLane(circleId, E2ee.linePhone, deleteCopies: deleteCopies);

  /// Circle admin only: server processing off for everybody, and the server's copies of the whole circle deleted.
  Future<void> removeForEveryone(String circleId, {required int defaultForNew, required int memberOptOut}) async {
    await controller.setPolicy(circleId, assist: false, defaultForNew: defaultForNew, memberOptOut: memberOptOut);
    await controller.deleteCopies(circleId, wholeCircle: true);
  }
}

/// The plain two-sentence explanation for step 1 (what the server will see).
String addServerExplanation(ServerProfile p) {
  if (p.isHome) {
    return 'The server in your home will be able to see where this circle\'s members are, so it can keep their history, trips and driving reports. '
        'It runs on a computer your circle owns, and each person still decides for themselves and can take it away at any time.';
  }
  if (p.known && p.profile == 'cloud') {
    return 'The server is rented from a company, and it will be able to see where this circle\'s members are, so it can keep their history, trips and driving reports. '
        'The company that runs the machine could read that too, so add it only if you trust them. Each person decides for themselves and can take it away at any time.';
  }
  return 'The server will be able to see where this circle\'s members are, so it can keep their history, trips and driving reports. '
      'Nobody has said that this server runs in your own home, so treat it like a rented one: add it only if you trust whoever runs it, and remember that each person decides for themselves and can take it away at any time.';
}
