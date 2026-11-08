import SwiftUI

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
                        Text(statusLine(m, snapshot: snap, now: context.date))
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

/// Compass style: an arrow towards the person with the north at the top. The
/// arrow does not follow how the watch is held (no heading sensor is used, to
/// save battery); it is a north-up map direction computed by the iPhone.
struct DirectionView: View {
    let memberId: String
    @EnvironmentObject var link: PhoneLink

    private var member: WMember? {
        return link.snapshot?.members.first(where: { $0.id == memberId })
    }

    var body: some View {
        if let m = member, let snap = link.snapshot, let dir = directionTo(m, in: snap) {
            let dist = dir.meters
            let bearing = dir.bearing
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Brand.sky.opacity(0.5), lineWidth: 3)
                    Text("N")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .offset(y: -52)
                    Image(systemName: "location.north.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .foregroundColor(Brand.lime)
                        .rotationEffect(.degrees(bearing))
                }
                .frame(width: 116, height: 116)
                .accessibilityHidden(true)
                Text(distanceText(dist))
                    .font(.title3.bold())
                Text("\(m.name) is \(compassWord(bearing))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .navigationTitle("Direction")
        } else {
            Text("No direction available.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
