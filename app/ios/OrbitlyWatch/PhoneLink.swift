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

    private let storeKey = "orbitly.snapshot.json"
    private let sessionKey = "orbitly.session"

    /// Commands waiting for the phone's answer (it arrives as `lastCommand` in
    /// the next snapshot). Main thread only.
    private var pending: [String: (Bool, String) -> Void] = [:]

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

    private func wipe() {
        snapshot = nil
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    /// Applies one application context. Everything runs on the main thread in
    /// arrival order, so a wipe can never be overtaken by older data.
    private func apply(context: [String: Any]) {
        DispatchQueue.main.async {
            let defaults = UserDefaults.standard
            if context["cleared"] as? Bool == true {
                self.wipe()
                defaults.removeObject(forKey: self.sessionKey)
            }
            // Another sign-in than the one the stored data belongs to: drop it.
            if let sid = context["session"] as? String, sid != defaults.string(forKey: self.sessionKey) {
                self.wipe()
                defaults.set(sid, forKey: self.sessionKey)
            }
            guard let json = context["snapshot"] as? String,
                  let decoded = WSnapshot.decode(json: json) else { return }
            if !decoded.signedIn {
                // The phone is signed out: forget everything.
                self.wipe()
                defaults.removeObject(forKey: self.sessionKey)
                return
            }
            defaults.set(json, forKey: self.storeKey)
            self.snapshot = decoded
            if let last = decoded.lastCommand {
                let text = last.message.isEmpty ? (last.ok ? "Done." : "The iPhone could not do it.") : last.message
                self.finish(last.id, last.ok, text)
            }
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

    // MARK: Sending

    private func finish(_ id: String, _ ok: Bool, _ message: String) {
        if let completion = pending.removeValue(forKey: id) {
            completion(ok, message)
        }
    }

    /// Sends one command ({id, cmd, at, arg}) to the iPhone. `completion` runs
    /// with the phone's own answer from the next snapshot, or with a plain
    /// failure text; it never reports success the phone did not confirm.
    func command(_ cmd: String, arg: String? = nil, completion: @escaping (Bool, String) -> Void) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            completion(false, "iPhone not reachable. Bring it closer and try again.")
            return
        }
        let id = UUID().uuidString
        var object: [String: Any] = [
            "id": id,
            "cmd": cmd,
            "at": Int64(Date().timeIntervalSince1970 * 1000.0),
        ]
        if let a = arg { object["arg"] = a }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            completion(false, "Could not prepare the request.")
            return
        }
        pending[id] = completion
        session.sendMessage(["json": text], replyHandler: { reply in
            let accepted = reply["ok"] as? Bool ?? false
            if !accepted {
                DispatchQueue.main.async {
                    self.finish(id, false, "The iPhone did not take it. Open Orbitly on it and try again.")
                }
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                self.finish(id, false, "The iPhone did not answer. Open Orbitly on it and try again.")
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            self.finish(id, false, "No confirmation from the iPhone yet. Check Orbitly there.")
        }
    }

    /// Asks the phone for a fresh snapshot; nothing waits for the answer.
    func refresh() {
        command("refresh") { _, _ in }
    }
}
