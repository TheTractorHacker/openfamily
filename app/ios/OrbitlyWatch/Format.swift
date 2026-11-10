import SwiftUI

// Brand colors (assets/brand/generate.py, dark theme): lime ring, sky satellite,
// charcoal surface.
enum Brand {
    static let lime = Color(red: 0.639, green: 0.902, blue: 0.208)
    static let sky = Color(red: 0.220, green: 0.741, blue: 0.973)
    static let charcoal = Color(red: 0.110, green: 0.118, blue: 0.133)
    static let sosRed = Color(red: 0.863, green: 0.149, blue: 0.149)
    static let warn = Color(red: 0.984, green: 0.749, blue: 0.141)
}

/// "Just now", "2 min ago", "3 h ago", "2 d ago".
func agoText(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "Just now" }
    let m = s / 60
    if m < 60 { return "\(m) min ago" }
    let h = m / 60
    if h < 24 { return "\(h) h ago" }
    return "\(h / 24) d ago"
}

/// "Updated just now", "Updated 25 s ago", then minutes: the direction screen shows
/// seconds because the arrow can only be as fresh as the other person's last fix.
func updatedText(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 5 { return "Updated just now" }
    if s < 60 { return "Updated \(s) s ago" }
    return "Updated \(agoText(date, now: now).lowercased())"
}

func distanceText(_ meters: Double) -> String {
    if Locale.current.usesMetricSystem {
        if meters < 1000 {
            return "\(Int((meters / 10).rounded()) * 10) m"
        }
        return String(format: "%.1f km", meters / 1000.0)
    }
    let feet = meters * 3.28084
    if feet < 528 {
        return "\(Int((feet / 10).rounded()) * 10) ft"
    }
    return String(format: "%.1f mi", meters / 1609.344)
}

/// Great-circle distance in meters.
func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r = 6371000.0
    let p1 = lat1 * Double.pi / 180
    let p2 = lat2 * Double.pi / 180
    let dp = (lat2 - lat1) * Double.pi / 180
    let dl = (lon2 - lon1) * Double.pi / 180
    let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
    return 2 * r * asin(min(1, sqrt(a)))
}

/// Initial bearing in degrees clockwise from north.
func bearingDegrees(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let p1 = lat1 * Double.pi / 180
    let p2 = lat2 * Double.pi / 180
    let dl = (lon2 - lon1) * Double.pi / 180
    let y = sin(dl) * cos(p2)
    let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
    let deg = atan2(y, x) * 180 / Double.pi
    return (deg + 360).truncatingRemainder(dividingBy: 360)
}

/// Distance and bearing from the signed-in person to `m`, when both are known.
func directionTo(_ m: WMember, in snapshot: WSnapshot) -> (meters: Double, bearing: Double)? {
    guard !m.you, let o = snapshot.origin, let olat = o.lat, let olon = o.lon,
          let lat = m.lat, let lon = m.lon else { return nil }
    return (distanceMeters(olat, olon, lat, lon), bearingDegrees(olat, olon, lat, lon))
}

/// "north", "north-east", ...
func compassWord(_ degrees: Double) -> String {
    let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
    let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    let index = Int((normalized / 45.0).rounded()) % 8
    return names[index]
}

/// The one-line status of a person. The phone writes `line` ("At Home",
/// "Driving 42 mph") in its own units; a person standing still with no saved place
/// shows how old the position is instead of an address.
func statusLine(_ m: WMember, paused: Bool, now: Date = Date()) -> String {
    if m.you && paused { return "Sharing paused" }
    if m.state == "none" { return "No location yet" }
    if m.state == "still" && m.place.isEmpty, m.lineAt == nil, let d = m.fixDate { return agoText(d, now: now) }
    // "Left Work" + "25 min ago", counted on the watch so a minute passing needs no new snapshot.
    if !m.line.isEmpty, let at = m.lineAt {
        return m.line + " " + agoText(Date(timeIntervalSince1970: at / 1000.0), now: now).lowercased()
    }
    if !m.line.isEmpty { return m.line }
    if let d = m.fixDate { return agoText(d, now: now) }
    return "Location shared"
}

func batteryText(_ m: WMember) -> String? {
    if m.battery < 0 { return nil }
    return "\(m.battery)%"
}

func colorFromARGB(_ argb: UInt32) -> Color {
    let r = Double((argb >> 16) & 0xFF) / 255.0
    let g = Double((argb >> 8) & 0xFF) / 255.0
    let b = Double(argb & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

// MARK: Smooth arrow (Precision Finding style)

/// The shortest signed turn in degrees, in -180...180: 359 to 1 is +2, not -358.
func shortestTurn(_ delta: Double) -> Double {
    var x = delta.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x < -180 { x += 360 }
    return x
}

/// Turns a stream of angles (any range, wrapping at 360) into one continuous angle
/// that eases towards each new value. The angle is "unwrapped" (it may grow past 360
/// or below 0), so a rotation effect never spins the long way round. The easing is
/// exponential and uses the time between frames, so it looks the same at 15 or 30
/// frames a second. A small dead band keeps the arrow still when the compass wobbles
/// by a degree. Reference type on purpose: it is advanced from a TimelineView, which
/// must not publish state changes. Main thread only.
final class AngleSmoother {
    private let tau: Double
    private let deadBand: Double
    private var primed = false
    private var lastRaw = 0.0
    private var target = 0.0
    private var shown = 0.0
    private var lastTime: Date? = nil

    /// `tau`: seconds to cover about 63% of the way (smaller = snappier).
    init(tau: Double = 0.14, deadBand: Double = 1.0) {
        self.tau = tau
        self.deadBand = deadBand
    }

    /// Feeds the newest raw angle and returns the angle to draw at `now`.
    func step(raw: Double, now: Date) -> Double {
        if !primed {
            primed = true
            lastRaw = raw
            target = raw
            shown = raw
            lastTime = now
            return shown
        }
        let turn = shortestTurn(raw - lastRaw)
        if abs(turn) >= deadBand {
            target += turn
            lastRaw = raw
        }
        var dt = 0.0
        if let t = lastTime { dt = now.timeIntervalSince(t) }
        lastTime = now
        if dt <= 0 { return shown }
        if dt > 0.5 { dt = 0.5 }
        let k = 1 - exp(-dt / tau)
        shown += (target - shown) * k
        if abs(target - shown) < 0.05 { shown = target }
        return shown
    }

    /// True once the drawn angle has reached its target (nothing is moving).
    var isSettled: Bool { return primed && shown == target }

    /// The angle last returned (no time passes).
    var current: Double { return shown }
}

/// The state of one direction screen, kept across frames: the two smoothers and the
/// "you are close" flag with some hysteresis so it does not flicker at the edge.
final class FindingState {
    let arrow = AngleSmoother()
    let north = AngleSmoother()
    private var closeFlag = false

    /// Below `kCloseEnterMeters` the bearing is noise (positions are coarse and the
    /// other phone reports every few seconds), so the screen says "close".
    func isClose(_ meters: Double) -> Bool {
        if closeFlag {
            if meters > kCloseLeaveMeters { closeFlag = false }
        } else if meters < kCloseEnterMeters {
            closeFlag = true
        }
        return closeFlag
    }
}

let kCloseEnterMeters = 15.0
let kCloseLeaveMeters = 30.0
