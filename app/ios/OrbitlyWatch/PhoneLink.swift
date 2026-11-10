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
            // Only a copy that decoded counts as "already shown".
            if snapshot != nil { storedJSON = saved }
        }
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    // MARK: Receiving

    /// Decoding and the UserDefaults write happen here, off the main thread that draws
    /// the arrow. The queue is serial, and it hands every result to the main queue
    /// in the order the contexts arrived, so a wipe can never be overtaken by older data.
    private let applyQueue = DispatchQueue(label: "app.openfamily.watch.apply", qos: .userInitiated)

    /// The JSON stored last. Only touched on `applyQueue`.
    private var storedJSON: String? = nil

    /// Forgets the stored data (on `applyQueue`) and clears the screen (on main).
    private func wipe(forgetSession: Bool) {
        storedJSON = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: storeKey)
        if forgetSession { defaults.removeObject(forKey: sessionKey) }
        DispatchQueue.main.async {
            self.snapshot = nil
        }
    }

    /// Applies one application context on `applyQueue`.
    private func apply(context: [String: Any]) {
        applyQueue.async {
            let defaults = UserDefaults.standard
            if context["cleared"] as? Bool == true {
                self.wipe(forgetSession: true)
            }
            // Another sign-in than the one the stored data belongs to: drop it.
            if let sid = context["session"] as? String, sid != defaults.string(forKey: self.sessionKey) {
                self.wipe(forgetSession: false)
                defaults.set(sid, forKey: self.sessionKey)
            }
            guard let json = context["snapshot"] as? String,
                  let decoded = WSnapshot.decode(json: json) else { return }
            if !decoded.signedIn {
                // The phone is signed out: forget everything.
                self.wipe(forgetSession: true)
                return
            }
            // The same text again (a repeated delivery): nothing to store or redraw.
            let unchanged = json == self.storedJSON
            if !unchanged {
                defaults.set(json, forKey: self.storeKey)
                self.storedJSON = json
            }
            DispatchQueue.main.async {
                if !unchanged && self.snapshot != decoded {
                    self.snapshot = decoded
                }
                if let last = decoded.lastCommand {
                    let text = last.message.isEmpty ? (last.ok ? "Done." : "The iPhone could not do it.") : last.message
                    self.finish(last.id, last.ok, text)
                }
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
            // The first "visible" can be sent before the session is active: say it again now.
            self.resendPresenceIfOnScreen()
        }
        if !context.isEmpty {
            apply(context: context)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        DispatchQueue.main.async {
            self.reachable = isReachable
            if isReachable { self.resendPresenceIfOnScreen() }
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

    /// Tells the iPhone whether this app is on screen ("visible", "visible ambient",
    /// "visible finding", "hidden") so it sends every few seconds only while it is
    /// (docs/design/WATCH_APPS.md, Cadence). "finding" is the direction screen: the
    /// iPhone then sends every 2 s. Fire and forget: no answer is expected, and a
    /// lost one is harmless (the iPhone forgets "visible" after 150 s).
    func presence(visible: Bool, ambient: Bool = false, finding: Bool = false) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else { return }
        var object: [String: Any] = [
            "id": UUID().uuidString,
            "cmd": visible ? "visible" : "hidden",
            "at": Int64(Date().timeIntervalSince1970 * 1000.0),
        ]
        if visible && ambient {
            object["arg"] = "ambient"
        } else if visible && finding {
            object["arg"] = "finding"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        session.sendMessage(["json": text], replyHandler: { _ in }, errorHandler: { _ in })
    }

    private var presenceTimer: Timer? = nil
    private var wantOnScreen = false
    private var wantAmbient = false
    private var wantFinding = false

    /// Called on scene phase changes. While active, "visible" is repeated once a minute.
    func setOnScreen(_ onScreen: Bool, ambient: Bool) {
        wantOnScreen = onScreen
        wantAmbient = ambient
        sendPresenceAndRearm()
    }

    /// The direction screen is open (true) or closed (false). Asks the iPhone to send
    /// position updates every 2 s instead of every 5 s while it is.
    func setFinding(_ on: Bool) {
        if on == wantFinding { return }
        wantFinding = on
        if wantOnScreen && !wantAmbient { sendPresenceAndRearm() }
    }

    private func resendPresenceIfOnScreen() {
        if wantOnScreen { sendPresenceAndRearm() }
    }

    private func sendPresenceAndRearm() {
        presenceTimer?.invalidate()
        presenceTimer = nil
        presence(visible: wantOnScreen, ambient: wantAmbient, finding: wantFinding)
        if wantOnScreen && !wantAmbient {
            presenceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.presence(visible: true, finding: self.wantFinding)
            }
        }
    }
}
