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

func speedText(_ mps: Double, units: String) -> String {
    if units == "metric" {
        return "\(Int((mps * 3.6).rounded())) km/h"
    }
    return "\(Int((mps * 2.23694).rounded())) mph"
}

func distanceText(_ meters: Double, units: String) -> String {
    if units == "metric" {
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

/// "north", "north-east", ...
func compassWord(_ degrees: Double) -> String {
    let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
    let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    let index = Int((normalized / 45.0).rounded()) % 8
    return names[index]
}

/// The one-line status of a person: "At Home", "Driving 42 mph", "2 min ago".
func statusLine(_ m: WMember, snapshot: WSnapshot, now: Date = Date()) -> String {
    if m.me && snapshot.isPaused { return "Sharing paused" }
    if !m.hasPosition { return "No location yet" }
    if m.stopped {
        if let d = m.fixDate { return "Updates stopped, \(agoText(d, now: now))" }
        return "Updates stopped"
    }
    switch m.state {
    case "driving":
        if let s = m.speedMps { return "Driving \(speedText(s, units: snapshot.units))" }
        return "Driving"
    case "bike": return "Cycling"
    case "boat": return "On a boat"
    case "plane": return "Flying"
    default: break
    }
    if let p = m.place, m.atPlace { return "At \(p)" }
    if m.state == "home" { return "At Home" }
    if m.state == "work" { return "At Work" }
    if m.state == "gym" { return "At the Gym" }
    if let d = m.fixDate { return agoText(d, now: now) }
    return "Location shared"
}

func batteryText(_ m: WMember) -> String? {
    guard let b = m.battery else { return nil }
    return "\(b)%"
}

func colorFromARGB(_ argb: UInt32) -> Color {
    let r = Double((argb >> 16) & 0xFF) / 255.0
    let g = Double((argb >> 8) & 0xFF) / 255.0
    let b = Double(argb & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}
