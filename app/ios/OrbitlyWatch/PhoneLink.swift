import Foundation
import WatchConnectivity
import WatchKit

/// The watch side of WatchConnectivity. The iPhone app holds every token and
/// key; this class only receives display snapshots and sends small commands.
/// Nothing here polls: the snapshot arrives when the iPhone sends it and the
/// last one is kept in UserDefaults so the app opens instantly and works
/// (read only) while the iPhone is out of reach.
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var snapshot: WSnapshot? = nil
    @Published var reachable: Bool = false
    /// Alerts that arrived by transferUserInfo since the last snapshot (memory only).
    @Published var lastAlerts: [WAlert] = []

    private let storeKey = "orbitly.snapshot.json"

    override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: storeKey) {
            snapshot = WSnapshot.decode(json: saved)
        }
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    // MARK: Receiving

    private let sessionKey = "orbitly.session"

    private func wipe() {
        snapshot = nil
        lastAlerts = []
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    /// Applies one application context. Everything runs on the main thread in
    /// arrival order, so a wipe can never be overtaken by older data.
    private func apply(context: [String: Any]) {
        DispatchQueue.main.async {
            let defaults = UserDefaults.standard
            let known = defaults.string(forKey: self.sessionKey)
            let sid = context["session"] as? String
            if context["cleared"] as? Bool == true {
                self.wipe()
                defaults.removeObject(forKey: self.sessionKey)
            }
            // Another sign-in than the one the stored data belongs to: drop it.
            if let sid = sid, sid != defaults.string(forKey: self.sessionKey) {
                if known != nil || self.snapshot != nil { self.wipe() }
                defaults.set(sid, forKey: self.sessionKey)
            }
            guard let json = context["snapshot"] as? String,
                  let decoded = WSnapshot.decode(json: json) else { return }
            if let current = defaults.string(forKey: self.sessionKey),
               !decoded.sessionId.isEmpty, decoded.sessionId != current { return }
            defaults.set(json, forKey: self.storeKey)
            self.snapshot = decoded
        }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let isReachable = session.isReachable
        let context = session.receivedApplicationContext
        DispatchQueue.main.async {
            self.reachable = isReachable
        }
        if !context.isEmpty {
            apply(context: context)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        DispatchQueue.main.async {
            self.reachable = isReachable
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(context: applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let json = userInfo["alert"] as? String,
              let data = json.data(using: .utf8),
              let alert = try? JSONDecoder().decode(WAlert.self, from: data) else { return }
        DispatchQueue.main.async {
            var next = self.lastAlerts.filter { $0.id != alert.id }
            next.insert(alert, at: 0)
            self.lastAlerts = Array(next.prefix(10))
            WKInterfaceDevice.current().play(.notification)
        }
    }

    // MARK: Sending

    /// Sends one command to the iPhone and reports plain words back.
    func send(_ payload: [String: Any], completion: @escaping (Bool, String) -> Void) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            completion(false, "iPhone not reachable. Bring it closer and try again.")
            return
        }
        session.sendMessage(payload, replyHandler: { reply in
            let ok = reply["ok"] as? Bool ?? false
            let message = reply["message"] as? String ?? ""
            DispatchQueue.main.async { completion(ok, message) }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                completion(false, "The iPhone did not answer. Open Orbitly on it and try again.")
            }
        })
    }

    func refresh() {
        send(["cmd": "refresh"]) { _, _ in }
    }
}
