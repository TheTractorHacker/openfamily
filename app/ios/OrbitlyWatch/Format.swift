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
func statusLine(_ m: WMember, snapshot: WSnapshot, now: Date = Date()) -> String {
    if m.you && snapshot.isPaused { return "Sharing paused" }
    if m.state == "none" { return "No location yet" }
    if m.state == "still" && m.place.isEmpty, let d = m.fixDate { return agoText(d, now: now) }
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
