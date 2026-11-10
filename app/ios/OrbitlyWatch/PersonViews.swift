import SwiftUI
import CoreLocation

/// One person: where they are, how fresh it is, battery, and the direction view.
struct PersonDetailView: View {
    let memberId: String
    @EnvironmentObject var link: PhoneLink

    private var member: WMember? {
        return link.snapshot?.members.first(where: { $0.id == memberId })
    }

    var body: some View {
        ScrollView {
            if let m = member, let snap = link.snapshot {
                VStack(spacing: 6) {
                    Avatar(member: m, size: 48)
                    Text(m.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    TimelineView(.everyMinute) { context in
                        Text(statusLine(m, paused: snap.isPaused, now: context.date))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    if !m.place.isEmpty {
                        Text(m.place).font(.footnote).foregroundColor(.secondary)
                    }
                    if !m.address.isEmpty {
                        let address = m.address
                        Text(address)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let d = m.fixDate {
                        TimelineView(.everyMinute) { context in
                            Text("Updated \(agoText(d, now: context.date))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let b = batteryText(m) {
                        Text("Battery \(b)")
                            .font(.caption2)
                            .foregroundColor((m.battery < 0 ? 100 : m.battery) <= 20 ? Brand.warn : .secondary)
                    }
                    if directionTo(m, in: snap) != nil {
                        NavigationLink(destination: DirectionView(memberId: m.id)) {
                            Label("Distance and direction", systemImage: "location.north.fill")
                        }
                    }
                    Text("To see the map, open Orbitly on your iPhone. It appears in the app switcher through Handoff.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                // Handoff: the iPhone offers to continue in Orbitly. Only the id is carried.
                .userActivity("app.openfamily.watch.person") { activity in
                    activity.isEligibleForHandoff = true
                    activity.title = "Orbitly"
                    activity.userInfo = ["memberId": memberId]
                }
            } else {
                Text("This person is no longer in the list.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Person")
    }
}

/// The watch compass. Started only while the direction screen is on screen and
/// awake, and stopped as soon as it is not (wrist down, screen left), because the
/// magnetometer costs battery. The latest value is a plain property read once per
/// frame by the arrow; nothing is published per sample, so a compass update never
/// re-evaluates a SwiftUI body (only `live` is published, once, when the first usable
/// reading arrives). Main thread only (the manager is created there, so CoreLocation
/// calls the delegate there too).
///
/// Only a TRUE-north heading is used: the bearing from the phone is a true bearing,
/// and mixing in the magnetic heading would be off by the local declination (10 to
/// 20 degrees in many regions). Without a true heading (location denied, no fix yet)
/// the screen keeps the north-up arrow. The last valid heading is kept across
/// stop/start, so waking the screen never snaps the arrow to north-up.
final class HeadingProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Degrees clockwise from true north: the last valid reading, or -1 if there has
    /// never been one. Deliberately not cleared by stop()/start().
    private(set) var degrees: Double = -1
    /// True once a valid true-north heading has been received. Published, but it flips
    /// at most once, so it never causes per-sample redraws.
    @Published private(set) var live = false

    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        if running { return }
        guard CLLocationManager.headingAvailable() else { return }
        running = true
        manager.startUpdatingHeading()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            // One position fix lets the system give a true-north heading
            // (without one only the magnetic heading is valid).
            manager.requestLocation()
        default:
            break
        }
    }

    func stop() {
        if !running { return }
        running = false
        manager.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // A negative accuracy means the reading is invalid; a negative true heading
        // means there is no location fix yet (only the magnetic one would be valid,
        // which is off by the declination, so it is ignored).
        if newHeading.headingAccuracy < 0 { return }
        if newHeading.trueHeading < 0 { return }
        degrees = newHeading.trueHeading
        if !live { live = true }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !running { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    // requestLocation() needs both of these; the position itself is not used here.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Precision Finding style: an arrow towards the person that turns with your wrist.
/// Arrow angle = bearing to the person minus the watch heading. The angle is
/// unwrapped and eased on every frame (30 a second, paused when the screen is dimmed
/// or, without a compass, once the arrow has settled), so it glides instead of jumping
/// when a new position or heading arrives. Without a compass reading it falls back to
/// the old north-up arrow.
struct DirectionView: View {
    let memberId: String
    @EnvironmentObject var link: PhoneLink
    @StateObject private var heading = HeadingProvider()
    @State private var state = FindingState()
    @Environment(\.isLuminanceReduced) private var dimmed

    private var member: WMember? {
        return link.snapshot?.members.first(where: { $0.id == memberId })
    }

    var body: some View {
        if let m = member, let snap = link.snapshot, let dir = directionTo(m, in: snap) {
            let close = state.isClose(dir.meters)
            ScrollView {
                VStack(spacing: 4) {
                    DirectionDial(bearing: dir.bearing, close: close, heading: heading, state: state, dimmed: dimmed)
                    if close {
                        Text("\(m.name) is close")
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                    } else {
                        Text(distanceText(dir.meters))
                            .font(.title3.bold())
                        Text("\(m.name) is \(compassWord(dir.bearing))")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let d = m.fixDate {
                        TimelineView(.periodic(from: Date(), by: 5)) { context in
                            Text(updatedText(d, now: context.date))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Direction")
            .onAppear {
                if !dimmed { heading.start() }
                link.setFinding(true)
            }
            .onDisappear {
                heading.stop()
                link.setFinding(false)
            }
            .onChange(of: dimmed) { isDimmed in
                if isDimmed { heading.stop() } else { heading.start() }
            }
        } else {
            Text("No direction available.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

/// The ring and the arrow. Redrawn once per frame by a TimelineView, which the system
/// throttles and pauses by itself; the work per frame is two small exponentials.
struct DirectionDial: View {
    let bearing: Double
    let close: Bool
    @ObservedObject var heading: HeadingProvider
    let state: FindingState
    let dimmed: Bool
    /// Set once both smoothers have settled while there is no compass: nothing can
    /// move then until a new bearing arrives, so the frame schedule is paused.
    @State private var idle = false

    /// Advances both smoothers to `date` and returns the angles to draw.
    private func frame(at date: Date) -> (arrow: Double, north: Double) {
        let h = heading.degrees
        let hasHeading = h >= 0
        // Where the person is relative to where the watch points; where north is.
        let a = state.arrow.step(raw: hasHeading ? bearing - h : bearing, now: date)
        let n = state.north.step(raw: hasHeading ? -h : 0, now: date)
        if !heading.live && !idle && state.arrow.isSettled && state.north.isSettled {
            // Not inside the view update: the state change must come after it.
            DispatchQueue.main.async { self.idle = true }
        }
        return (a, n)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: dimmed || (idle && !heading.live))) { context in
            let angles = frame(at: context.date)
            let arrowAngle = angles.arrow
            let northAngle = angles.north
            ZStack {
                Circle()
                    .stroke(Brand.sky.opacity(0.5), lineWidth: 3)
                ZStack {
                    Text("N")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(-northAngle))
                        .offset(y: -52)
                }
                .frame(width: 116, height: 116)
                .rotationEffect(.degrees(northAngle))
                Image(systemName: "location.north.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .foregroundColor(Brand.lime)
                    .opacity(close ? 0.3 : 1.0)
                    .rotationEffect(.degrees(arrowAngle))
            }
            .frame(width: 116, height: 116)
        }
        .onChange(of: bearing) { _ in idle = false }
        .accessibilityHidden(true)
    }
}
