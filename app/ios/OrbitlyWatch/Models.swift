import Foundation

// The snapshot the iPhone pushes (see app/lib/services/watch/watch_snapshot.dart
// for the JSON shape). Decoding is deliberately forgiving: every field has a
// default, so an older or newer iPhone app never makes the watch app crash.

struct WMe: Decodable {
    var id: String = ""
    var name: String = ""
    var sharing: Bool = true
    var pausedUntil: Double? = nil

    init() {}

    enum CodingKeys: String, CodingKey { case id, name, sharing, pausedUntil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        sharing = (try? c.decodeIfPresent(Bool.self, forKey: .sharing)) ?? true
        pausedUntil = (try? c.decodeIfPresent(Double.self, forKey: .pausedUntil)) ?? nil
    }
}

struct WMember: Decodable, Identifiable {
    var id: String = ""
    var name: String = ""
    var initials: String = "?"
    var color: UInt32 = 0xFF38BDF8
    var me: Bool = false
    var state: String = "still"
    var speedMps: Double? = nil
    var place: String? = nil
    var atPlace: Bool = false
    var address: String? = nil
    var fixTs: Double? = nil
    var battery: Int? = nil
    var stopped: Bool = false
    var hasPosition: Bool = false
    var distanceM: Double? = nil
    var bearingDeg: Double? = nil

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, initials, color, me, state, speedMps, place, atPlace, address
        case fixTs, battery, stopped, hasPosition, distanceM, bearingDeg
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        initials = (try? c.decodeIfPresent(String.self, forKey: .initials)) ?? "?"
        color = (try? c.decodeIfPresent(UInt32.self, forKey: .color)) ?? 0xFF38BDF8
        me = (try? c.decodeIfPresent(Bool.self, forKey: .me)) ?? false
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "still"
        speedMps = (try? c.decodeIfPresent(Double.self, forKey: .speedMps)) ?? nil
        place = (try? c.decodeIfPresent(String.self, forKey: .place)) ?? nil
        atPlace = (try? c.decodeIfPresent(Bool.self, forKey: .atPlace)) ?? false
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? nil
        fixTs = (try? c.decodeIfPresent(Double.self, forKey: .fixTs)) ?? nil
        battery = (try? c.decodeIfPresent(Int.self, forKey: .battery)) ?? nil
        stopped = (try? c.decodeIfPresent(Bool.self, forKey: .stopped)) ?? false
        hasPosition = (try? c.decodeIfPresent(Bool.self, forKey: .hasPosition)) ?? false
        distanceM = (try? c.decodeIfPresent(Double.self, forKey: .distanceM)) ?? nil
        bearingDeg = (try? c.decodeIfPresent(Double.self, forKey: .bearingDeg)) ?? nil
    }

    /// When the position was last updated.
    var fixDate: Date? {
        guard let t = fixTs else { return nil }
        return Date(timeIntervalSince1970: t / 1000.0)
    }
}

struct WCircle: Decodable, Identifiable {
    var id: String = ""
    var name: String = ""
    var unread: Int = 0
    var active: Bool = false
    var members: [WMember] = []

    init() {}

    enum CodingKeys: String, CodingKey { case id, name, unread, active, members }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
        members = (try? c.decodeIfPresent([WMember].self, forKey: .members)) ?? []
    }
}

struct WAlert: Decodable, Identifiable {
    var id: String = ""
    var kind: String = ""
    var title: String = ""
    var body: String = ""
    var ts: Double = 0
    var active: Bool = false

    init() {}

    enum CodingKeys: String, CodingKey { case id, kind, title, body, ts, active }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        ts = (try? c.decodeIfPresent(Double.self, forKey: .ts)) ?? 0
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
    }

    var date: Date { Date(timeIntervalSince1970: ts / 1000.0) }
}

struct WSnapshot: Decodable {
    var version: Int = 1
    var sessionId: String = ""
    var ts: Double = 0
    var units: String = "imperial"
    var me: WMe = WMe()
    var circles: [WCircle] = []
    var alerts: [WAlert] = []
    var quickReplies: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case sessionId = "sid"
        case ts, units, me, circles, alerts, quickReplies
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        ts = (try? c.decodeIfPresent(Double.self, forKey: .ts)) ?? 0
        units = (try? c.decodeIfPresent(String.self, forKey: .units)) ?? "imperial"
        me = (try? c.decodeIfPresent(WMe.self, forKey: .me)) ?? WMe()
        circles = (try? c.decodeIfPresent([WCircle].self, forKey: .circles)) ?? []
        alerts = (try? c.decodeIfPresent([WAlert].self, forKey: .alerts)) ?? []
        quickReplies = (try? c.decodeIfPresent([String].self, forKey: .quickReplies)) ?? []
    }

    static func decode(json: String) -> WSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WSnapshot.self, from: data)
    }

    var date: Date { Date(timeIntervalSince1970: ts / 1000.0) }

    /// The circle whose people are listed.
    var activeCircle: WCircle? {
        return circles.first(where: { $0.active }) ?? circles.first
    }

    var unreadTotal: Int {
        return circles.reduce(0) { $0 + $1.unread }
    }

    var isPaused: Bool { !me.sharing }
}
