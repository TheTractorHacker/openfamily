import Flutter
import Foundation
import WatchConnectivity

/// iPhone end of the Apple Watch link (docs/design/WATCH_APPS.md, Apple Watch).
///
/// Same MethodChannel contract as the Wear OS plugin (WatchBridgePlugin.kt), so
/// ONE Dart bridge (app/lib/services/watch/watch_bridge.dart) drives both:
///   publish({json, urgent}) -> bool   latest snapshot via updateApplicationContext
///                                     (`urgent` has no WatchConnectivity equivalent; a
///                                     bare json string from older Dart code also works)
///   clear()       -> bool   wipe for the watch; true only once it was handed over
///   allowPublish()          sign-in / switch on: sending is allowed again
///   status()      -> map    {available, nodes, names}; nodes is 1 with a watch app
/// and calls back into Dart: command(json), peerChanged().
///
/// Safe without a watch: on an iPad `WCSession.isSupported()` is false, with no
/// paired watch every call answers "not available" and nothing is sent.
final class WatchBridge: NSObject, WCSessionDelegate {
  static let shared = WatchBridge()

  private var channel: FlutterMethodChannel?
  private var session: WCSession?

  // Sign-out must reach the watch even when it is out of reach at that moment.
  // Two persisted facts, deliberately separate:
  //  - blocked: no family data may be sent (after clear, until allowPublish);
  //  - clearUndelivered: the wipe has not reached the watch yet. A new sign-in
  //    does NOT reset it; it is cleared only after a context carrying the wipe
  //    or a snapshot of the NEW session was accepted by WatchConnectivity.
  // Every context also carries the sign-in's session id; the watch drops what
  // it stored for any other session, so a previous user's data is never shown.
  private let blockedKey = "orbitly.watch.blocked"
  private let undeliveredKey = "orbitly.watch.clearUndelivered"
  private let sessionKey = "orbitly.watch.sessionId"
  private var blocked: Bool {
    get { UserDefaults.standard.bool(forKey: blockedKey) }
    set { UserDefaults.standard.set(newValue, forKey: blockedKey) }
  }
  private var clearUndelivered: Bool {
    get { UserDefaults.standard.bool(forKey: undeliveredKey) }
    set { UserDefaults.standard.set(newValue, forKey: undeliveredKey) }
  }
  private var sessionId: String? {
    get { UserDefaults.standard.string(forKey: sessionKey) }
    set { UserDefaults.standard.set(newValue, forKey: sessionKey) }
  }

  /// Sends the wipe (plus the current session id, when signed in) if a usable
  /// session exists. Safe to repeat.
  private func deliverClearIfPending() {
    guard clearUndelivered, let s = session, s.activationState == .activated,
      s.isPaired, s.isWatchAppInstalled
    else { return }
    for t in s.outstandingUserInfoTransfers { t.cancel() }
    var ctx: [String: Any] = ["cleared": true, "sentAt": Date().timeIntervalSince1970]
    if !blocked, let id = sessionId { ctx["session"] = id }
    do {
      try s.updateApplicationContext(ctx)
      clearUndelivered = false
    } catch {
      // stays undelivered; retried on the next session event
    }
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "app.openfamily/watch", binaryMessenger: messenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
    if WCSession.isSupported() {
      let s = WCSession.default
      s.delegate = self
      s.activate()
      session = s
    }
  }

  private func statusMap() -> [String: Any] {
    guard let s = session else {
      return ["available": false, "nodes": 0, "names": [String]()]
    }
    let there = s.isPaired && s.isWatchAppInstalled
    return ["available": true, "nodes": there ? 1 : 0, "names": [String]()]
  }

  private func usable() -> WCSession? {
    guard let s = session, s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else {
      return nil
    }
    return s
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(statusMap())
    case "publish":
      if blocked {
        // Signed out or switched off: never send family data.
        deliverClearIfPending()
        result(false)
        return
      }
      // First publish of a session that has no identity yet (restored login).
      if sessionId == nil { sessionId = UUID().uuidString }
      let json = (call.arguments as? String) ?? ((call.arguments as? [String: Any])?["json"] as? String)
      if let s = usable(), let json = json, let sid = sessionId {
        // Latest value wins; delivered when the watch next wakes. No polling.
        do {
          try s.updateApplicationContext(
            ["snapshot": json, "session": sid, "sentAt": Date().timeIntervalSince1970])
          // The session id makes the watch drop any older user's data.
          clearUndelivered = false
          result(true)
          return
        } catch {}
      }
      result(false)
    case "clear":
      blocked = true
      clearUndelivered = true
      sessionId = nil
      deliverClearIfPending()
      // True only when the wipe was handed to WatchConnectivity.
      result(!clearUndelivered)
    case "allowPublish":
      // Signing in (or switching on): a NEW identity, so a previous user's data
      // on the watch is dropped. An undelivered wipe is sent FIRST, with it.
      sessionId = UUID().uuidString
      blocked = false
      deliverClearIfPending()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func notifyPeerChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("peerChanged", arguments: nil)
    }
  }

  // MARK: WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    deliverClearIfPending()
    notifyPeerChanged()
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // The user switched to another watch: activate again for the new one.
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    deliverClearIfPending()
    notifyPeerChanged()
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    deliverClearIfPending()
    notifyPeerChanged()
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    // The watch sends {"json": "<command>"}. The result of the command comes back
    // in the next snapshot (`lastCommand`); this reply only says "the phone has it".
    guard let json = message["json"] as? String else {
      replyHandler(["ok": false])
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let ch = self?.channel else {
        replyHandler(["ok": false])
        return
      }
      ch.invokeMethod("command", arguments: json) { response in
        // nil = Dart handled it; FlutterError or "not implemented" = it did not.
        replyHandler(["ok": response == nil])
      }
    }
  }
}
