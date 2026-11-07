import SwiftUI
import WatchKit

/// Home screen: connection banner, the people, then the safety actions.
struct RootView: View {
    @EnvironmentObject var link: PhoneLink

    var body: some View {
        NavigationStack {
            List {
                StatusBanner()
                if let snap = link.snapshot {
                    if let circle = snap.activeCircle {
                        Section(header: Text(circle.name)) {
                            if circle.members.isEmpty {
                                Text("No one to show yet.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            ForEach(circle.members) { member in
                                NavigationLink(destination: PersonDetailView(memberId: member.id)) {
                                    MemberRow(member: member, snapshot: snap)
                                }
                            }
                        }
                    }
                    Section(header: Text("Safety")) {
                        NavigationLink(destination: SosView()) {
                            Label("SOS", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(Brand.sosRed)
                        }
                        CommandButton(title: "I'm OK", systemImage: "checkmark.circle.fill",
                                      payload: ["cmd": "checkin"])
                        if snap.isPaused {
                            CommandButton(title: "Resume sharing", systemImage: "location.fill",
                                          payload: ["cmd": "resume"])
                        } else {
                            NavigationLink(destination: PauseView()) {
                                Label("Pause sharing", systemImage: "location.slash.fill")
                            }
                        }
                    }
                    Section(header: Text("Messages")) {
                        NavigationLink(destination: RepliesView()) {
                            HStack {
                                Label("Quick replies", systemImage: "bubble.left.fill")
                                Spacer()
                                if snap.unreadTotal > 0 {
                                    UnreadBadge(count: snap.unreadTotal)
                                }
                            }
                        }
                        NavigationLink(destination: AlertsView()) {
                            Label("Alerts", systemImage: "bell.fill")
                        }
                    }
                } else {
                    Text("Open Orbitly on your iPhone to show your family here.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Orbitly")
        }
    }
}

/// "iPhone not reachable" plus how old the data is. Shown only when it matters.
struct StatusBanner: View {
    @EnvironmentObject var link: PhoneLink

    var body: some View {
        if !link.reachable {
            VStack(alignment: .leading, spacing: 2) {
                Text("iPhone not reachable")
                    .font(.footnote)
                    .foregroundColor(Brand.warn)
                if let snap = link.snapshot, snap.ts > 0 {
                    TimelineView(.everyMinute) { context in
                        Text("Last update \(agoText(snap.date, now: context.date))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.bold())
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Brand.lime))
            .accessibilityLabel("\(count) unread")
    }
}

struct Avatar: View {
    let member: WMember
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(colorFromARGB(member.color))
            Text(member.initials)
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MemberRow: View {
    let member: WMember
    let snapshot: WSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Avatar(member: member)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.me ? "\(member.name) (you)" : member.name)
                    .font(.headline)
                    .lineLimit(1)
                TimelineView(.everyMinute) { context in
                    Text(statusLine(member, snapshot: snapshot, now: context.date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let b = batteryText(member) {
                Text(b)
                    .font(.caption2)
                    .foregroundColor((member.battery ?? 100) <= 20 ? Brand.warn : .secondary)
            }
        }
    }
}

/// A button that sends one command to the iPhone and shows the answer.
struct CommandButton: View {
    let title: String
    let systemImage: String
    let payload: [String: Any]

    @EnvironmentObject var link: PhoneLink
    @State private var busy = false
    @State private var message: String? = nil
    @State private var succeeded = true

    init(title: String, systemImage: String, payload: [String: Any]) {
        self.title = title
        self.systemImage = systemImage
        self.payload = payload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: run) {
                Label(title, systemImage: systemImage)
            }
            .disabled(busy)
            if busy {
                ProgressView()
            }
            if let m = message {
                Text(m)
                    .font(.footnote)
                    .foregroundColor(succeeded ? .secondary : Brand.warn)
            }
        }
    }

    private func run() {
        busy = true
        message = nil
        link.send(payload) { ok, text in
            busy = false
            succeeded = ok
            message = text.isEmpty ? nil : text
            WKInterfaceDevice.current().play(ok ? .success : .failure)
        }
    }
}

struct PauseView: View {
    var body: some View {
        List {
            CommandButton(title: "For 1 hour", systemImage: "clock",
                          payload: ["cmd": "pause", "minutes": 60])
            CommandButton(title: "For 4 hours", systemImage: "clock",
                          payload: ["cmd": "pause", "minutes": 240])
            CommandButton(title: "For 24 hours", systemImage: "clock",
                          payload: ["cmd": "pause", "minutes": 1440])
        }
        .navigationTitle("Pause sharing")
    }
}

/// Fixed phrases only: nothing is typed on the watch.
struct RepliesView: View {
    @EnvironmentObject var link: PhoneLink

    private let fallback = ["On my way", "OK", "Running late", "Call me", "Yes", "No"]

    var body: some View {
        let circle = link.snapshot?.activeCircle
        let phrases = (link.snapshot?.quickReplies.isEmpty ?? true) ? fallback : (link.snapshot?.quickReplies ?? fallback)
        List {
            if let c = circle {
                Text("To \(c.name)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                ForEach(phrases, id: \.self) { phrase in
                    CommandButton(title: phrase, systemImage: "paperplane.fill",
                                  payload: ["cmd": "reply", "circleId": c.id, "text": phrase])
                }
            } else {
                Text("Open Orbitly on your iPhone first.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Replies")
        .onAppear {
            if let c = circle, c.unread > 0 {
                link.send(["cmd": "markRead", "circleId": c.id]) { _, _ in }
            }
        }
    }
}

struct AlertsView: View {
    @EnvironmentObject var link: PhoneLink

    private var alerts: [WAlert] {
        var all = link.snapshot?.alerts ?? []
        for extra in link.lastAlerts where !all.contains(where: { $0.id == extra.id }) {
            all.insert(extra, at: 0)
        }
        return all
    }

    var body: some View {
        List {
            if alerts.isEmpty {
                Text("No alerts.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(alerts) { alert in
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.headline)
                        .foregroundColor(alert.kind == "sos" && alert.active ? Brand.sosRed : .primary)
                    if !alert.body.isEmpty {
                        Text(alert.body).font(.footnote)
                    }
                    Text(agoText(alert.date))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Alerts")
    }
}
