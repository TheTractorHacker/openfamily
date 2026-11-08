import Foundation

// The snapshot the iPhone pushes. The JSON contract is shared with the Wear OS
// app and defined in docs/design/WATCH_APPS.md (builder:
// app/lib/services/watch/watch_snapshot.dart). Decoding is deliberately
// forgiving: every field has a default, so an older or newer iPhone app never
// makes the watch app crash.

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when missing or of the wrong type.
    func val<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        return ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
    }

    func opt<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        return (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

struct WScope: Decodable {
    var id: String = "all"
    var name: String = "Everyone"
    var priv: Bool = false

    init() {}
    enum CodingKeys: String, CodingKey { case id, name, priv = "private" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(String.self, .id, "all")
        name = c.val(String.self, .name, "Everyone")
        priv = c.val(Bool.self, .priv, false)
    }
}

struct WMe: Decodable {
    var sharing: String = "on"
    var pausedUntil: Double? = nil

    init() {}
    enum CodingKeys: String, CodingKey { case sharing, pausedUntil }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharing = c.val(String.self, .sharing, "on")
        pausedUntil = c.opt(Double.self, .pausedUntil)
    }
}

struct WMember: Decodable, Identifiable {
    var id: String = ""
    var name: String = ""
    var initials: String = "?"
    var color: UInt32 = 0xFF38BDF8
    var lat: Double? = nil
    var lon: Double? = nil
    var fixAt: Double? = nil
    var battery: Int = -1
    var state: String = "none"
    var speedKmh: Int? = nil
    var place: String = ""
    var address: String = ""
    var line: String = ""
    /// When set, "<line> 25 min ago": the phone leaves relative times out of `line`.
    var lineAt: Double? = nil
    var priv: Bool = false
    var you: Bool = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case id, name, initials, color, lat, lon, fixAt, battery, state, speedKmh
        case place, address, line, lineAt, priv = "private", you
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(String.self, .id, "")
        name = c.val(String.self, .name, "")
        initials = c.val(String.self, .initials, "?")
        color = c.val(UInt32.self, .color, 0xFF38BDF8)
        lat = c.opt(Double.self, .lat)
        lon = c.opt(Double.self, .lon)
        fixAt = c.opt(Double.self, .fixAt)
        battery = c.val(Int.self, .battery, -1)
        state = c.val(String.self, .state, "none")
        speedKmh = c.opt(Int.self, .speedKmh)
        place = c.val(String.self, .place, "")
        address = c.val(String.self, .address, "")
        line = c.val(String.self, .line, "")
        lineAt = c.opt(Double.self, .lineAt).flatMap { $0 > 0 ? $0 : nil }
        priv = c.val(Bool.self, .priv, false)
        you = c.val(Bool.self, .you, false)
    }

    var fixDate: Date? {
        guard let t = fixAt else { return nil }
        return Date(timeIntervalSince1970: t / 1000.0)
    }

    var hasPosition: Bool { return lat != nil && lon != nil }
}

struct WCircle: Decodable, Identifiable {
    var id: String = ""
    var name: String = ""
    var unread: Int = 0
    var priv: Bool = false

    init() {}
    enum CodingKeys: String, CodingKey { case id, name, unread, priv = "private" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(String.self, .id, "")
        name = c.val(String.self, .name, "")
        unread = c.val(Int.self, .unread, 0)
        priv = c.val(Bool.self, .priv, false)
    }
}

struct WAlert: Decodable, Identifiable {
    var id: String = ""
    var kind: String = ""
    var from: String = ""
    var at: Double = 0
    var note: String = ""
    var active: Bool = true

    init() {}
    enum CodingKeys: String, CodingKey { case id, kind, from, at, note, active }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(String.self, .id, "")
        kind = c.val(String.self, .kind, "")
        from = c.val(String.self, .from, "")
        at = c.val(Double.self, .at, 0)
        note = c.val(String.self, .note, "")
        active = c.val(Bool.self, .active, true)
    }

    var date: Date { return Date(timeIntervalSince1970: at / 1000.0) }

    var title: String {
        switch kind {
        case "sos": return "SOS from \(from)"
        case "help": return "Help request from \(from)"
        default: return "Check-in from \(from)"
        }
    }
}

struct WLastCommand: Decodable {
    var id: String = ""
    var cmd: String = ""
    var ok: Bool = false
    var message: String = ""

    init() {}
    enum CodingKeys: String, CodingKey { case id, cmd, ok, message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(String.self, .id, "")
        cmd = c.val(String.self, .cmd, "")
        ok = c.val(Bool.self, .ok, false)
        message = c.val(String.self, .message, "")
    }
}

struct WSnapshot: Decodable {
    var version: Int = 1
    var ts: Double = 0
    var signedIn: Bool = true
    var scope: WScope = WScope()
    var circles: [WCircle] = []
    var me: WMe = WMe()
    var unread: Int = 0
    var members: [WMember] = []
    var alerts: [WAlert] = []
    var lastCommand: WLastCommand? = nil

    init() {}
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case ts, signedIn, scope, circles, me, unread, members, alerts, lastCommand
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.val(Int.self, .version, 1)
        ts = c.val(Double.self, .ts, 0)
        signedIn = c.val(Bool.self, .signedIn, true)
        scope = c.val(WScope.self, .scope, WScope())
        circles = c.val([WCircle].self, .circles, [])
        me = c.val(WMe.self, .me, WMe())
        unread = c.val(Int.self, .unread, 0)
        members = c.val([WMember].self, .members, [])
        alerts = c.val([WAlert].self, .alerts, [])
        lastCommand = c.opt(WLastCommand.self, .lastCommand)
    }

    static func decode(json: String) -> WSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WSnapshot.self, from: data)
    }

    var date: Date { return Date(timeIntervalSince1970: ts / 1000.0) }
    var isPaused: Bool { return me.sharing == "paused" }

    /// Where the signed-in person is, the origin for distance and direction.
    var origin: WMember? {
        return members.first(where: { $0.you && $0.hasPosition })
    }
}
