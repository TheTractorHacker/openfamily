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
      if let s = usable(), let json = call.arguments as? String {
        // Latest value wins; delivered when the watch next wakes. No polling.
        try? s.updateApplicationContext(["snapshot": json, "sentAt": Date().timeIntervalSince1970])
      }
      result(nil)
    case "alert":
      if let s = usable(), let json = call.arguments as? String {
        s.transferUserInfo(["alert": json])
      }
      result(nil)
    case "clear":
      if let s = session, s.activationState == .activated, s.isPaired, s.isWatchAppInstalled {
        for t in s.outstandingUserInfoTransfers { t.cancel() }
        try? s.updateApplicationContext(["cleared": true, "sentAt": Date().timeIntervalSince1970])
      }
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
    notifyStatusChanged()
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // The user switched to another watch: activate again for the new one.
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    notifyStatusChanged()
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
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
