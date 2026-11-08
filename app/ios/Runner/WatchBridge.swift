import Flutter
import Foundation
import WatchConnectivity

/// iPhone end of the Apple Watch link (docs/design/WATCH_APPS_APPLE.md).
///
/// Dart (app/lib/services/watch/watch_bridge_ios.dart) builds a compact,
/// already-decrypted snapshot and hands it over on the `app.openfamily/watch`
/// channel; this class forwards it with WatchConnectivity and passes the
/// watch's commands (SOS, check-in, pause, quick reply) back to Dart. The
/// phone stays the only holder of tokens and keys.
///
/// Safe without a watch: on an iPad `WCSession.isSupported()` is false, with no
/// paired watch every call answers "not paired" and nothing is sent.
final class WatchBridge: NSObject, WCSessionDelegate {
  static let shared = WatchBridge()

  private var channel: FlutterMethodChannel?
  private var session: WCSession?

  // Sign-out must reach the watch even when it is out of reach at that moment.
  // Two persisted facts, deliberately separate:
  //  - blocked: no family data may be sent (after clear, until signedIn/resume);
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
      return ["supported": false, "paired": false, "installed": false, "reachable": false]
    }
    return [
      "supported": true,
      "paired": s.isPaired,
      "installed": s.isWatchAppInstalled,
      "reachable": s.isReachable,
      "activated": s.activationState == .activated,
    ]
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
    case "snapshot":
      if blocked || sessionId == nil {
        // Signed out or switched off: never send family data.
        deliverClearIfPending()
      } else if let s = usable(), let json = call.arguments as? String, let sid = sessionId {
        // Latest value wins; delivered when the watch next wakes. No polling.
        do {
          try s.updateApplicationContext(
            ["snapshot": json, "session": sid, "sentAt": Date().timeIntervalSince1970])
          // The new session id makes the watch drop any older user's data.
          clearUndelivered = false
        } catch {}
      }
      result(nil)
    case "alert":
      if !blocked, let s = usable(), let json = call.arguments as? String {
        s.transferUserInfo(["alert": json])
      }
      result(nil)
    case "clear":
      blocked = true
      clearUndelivered = true
      let keep = (call.arguments as? [String: Any])?["keepSession"] as? Bool ?? false
      if !keep { sessionId = nil }
      deliverClearIfPending()
      result(nil)
    case "signedIn":
      // A real sign-in: new session id. Any undelivered wipe is sent FIRST.
      if let id = call.arguments as? String, !id.isEmpty {
        sessionId = id
        blocked = false
        deliverClearIfPending()
      }
      result(nil)
    case "resume":
      // The setting was switched back on (same session): sending is allowed again.
      if sessionId != nil { blocked = false }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func notifyStatusChanged() {
    let status = statusMap()
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("statusChanged", arguments: status)
    }
  }

  // MARK: WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    deliverClearIfPending()
    notifyStatusChanged()
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // The user switched to another watch: activate again for the new one.
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    deliverClearIfPending()
    notifyStatusChanged()
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    deliverClearIfPending()
    notifyStatusChanged()
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    let notReady: [String: Any] = [
      "ok": false,
      "message": "Open Orbitly on the iPhone and try again.",
    ]
    DispatchQueue.main.async { [weak self] in
      guard let ch = self?.channel else {
        replyHandler(notReady)
        return
      }
      ch.invokeMethod("command", arguments: message) { response in
        if let map = response as? [String: Any] {
          replyHandler(map)
        } else {
          replyHandler(notReady)
        }
      }
    }
  }
}
