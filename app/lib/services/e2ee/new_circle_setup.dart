import 'add_server_flow.dart';
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'processing_controller.dart';

// "End-to-end encryption out of the box" (docs/design/PRIVACY_PROCESSING.md section 24). A new circle is
// Private and the server takes part as its own device. This file is only the decision logic on top of
// [AddServerFlow]: it adds no protocol and signs nothing for anybody but the person creating the circle.

/// How a new circle is set up.
enum NewCircleMode {
  /// Private (end-to-end encrypted between phones) with the server as a participant: members are on the server by
  /// default and each can switch it off for themselves.
  privateServer,

  /// Private, phones only: the server keeps nothing readable.
  privatePhones,

  /// Normal: the server keeps readable locations, no end-to-end encryption.
  normal,
}

/// What happened when the creator's phone tried to switch the server on for the new circle.
enum NewCircleServerOutcome {
  /// Server processing is on (members on the server by default) and the creator's own lane is the server.
  serverOn,

  /// The server's key waits for THIS phone's approval: show the add-server sheet (compare the code, approve, OK).
  approveServer,

  /// The server asked to join, but only a server administrator can approve it. The circle is phones-only until then.
  waitingForServerAdmin,

  /// The server gave two different answers about its own key. Nothing was signed; the person must check the server.
  keyConflict,

  /// This server has no server device (switched off, or an older server): the circle stays phones-only.
  unavailable,
}

class NewCircleSetup {
  NewCircleSetup(this.controller);
  final ProcessingController controller;

  /// True when this server can take part in a Private circle as its own device: it has an approved key, runs the
  /// built-in device, or is asking to join. Never throws (an older server reads as unavailable).
  Future<bool> serverAvailable() async {
    try {
      final ServerProfile p = await controller.serverProfile();
      if (p.device != null || p.builtin || p.enabled) return true;
      return (await controller.serverJoin()).waiting;
    } catch (_) {
      return false;
    }
  }

  /// Right after the creator made [circleId] Private, having chosen "Private, with your server": turns server
  /// processing on (server as the default for members, opt-out allowed, or required for everyone when
  /// [requireServer]) and signs the creator's OWN server lane. Nobody else is signed for: every other member's own
  /// phone does that, with a notice, or asks them. Errors ([LanesNotReady], StateError, network) are thrown.
  Future<NewCircleServerOutcome> turnOn(String circleId, {bool requireServer = false}) async {
    final AddServerFlow flow = AddServerFlow(controller);
    final AddServerPlan plan = await flow.plan(circleId);
    switch (plan.state) {
      case AddServerState.ready:
        await flow.confirm(circleId, plan, memberOptOut: requireServer ? E2ee.optOutRequiredServer : E2ee.optOutAllowed);
        return NewCircleServerOutcome.serverOn;
      case AddServerState.alreadyAdded:
        return NewCircleServerOutcome.serverOn;
      case AddServerState.approveServer:
        return NewCircleServerOutcome.approveServer;
      case AddServerState.serverWaiting:
        return NewCircleServerOutcome.waitingForServerAdmin;
      case AddServerState.keyConflict:
        return NewCircleServerOutcome.keyConflict;
      case AddServerState.notPrivate:
      case AddServerState.serverMissing:
      case AddServerState.needsAdmin:
      case AddServerState.legacy:
      case AddServerState.membersNeedUpdate:
        return NewCircleServerOutcome.unavailable;
    }
  }

  /// After the add-server sheet approved the server and switched it on (opt-out allowed): applies "required for
  /// everyone" if the creator asked for it. Does nothing when server processing is not on.
  Future<void> requireForEveryone(String circleId) async {
    final ProcessingSnapshot s = await controller.load(circleId, force: true);
    if (!s.assistOn || s.required || !s.iAmAdmin) return;
    await controller.setPolicy(circleId, assist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer);
  }
}
