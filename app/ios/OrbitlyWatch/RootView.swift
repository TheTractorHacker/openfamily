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
                    Section(header: Text(snap.scope.name)) {
                        if snap.members.isEmpty {
                            Text("No one to show yet.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        ForEach(snap.members) { member in
                            NavigationLink(destination: PersonDetailView(memberId: member.id)) {
                                MemberRow(member: member, snapshot: snap)
                            }
                        }
                    }
                    Section(header: Text("Safety")) {
                        NavigationLink(destination: SosView()) {
                            Label("SOS", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(Brand.sosRed)
                        }
                        CommandButton(title: "I'm OK", systemImage: "checkmark.circle.fill", cmd: "checkin")
                        if snap.isPaused {
                            CommandButton(title: "Resume sharing", systemImage: "location.fill", cmd: "resume")
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
                                if snap.unread > 0 {
                                    UnreadBadge(count: snap.unread)
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
                Text(member.you ? "\(member.name) (you)" : member.name)
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
                    .foregroundColor((member.battery < 0 ? 100 : member.battery) <= 20 ? Brand.warn : .secondary)
            }
        }
    }
}

/// A button that sends one command to the iPhone and shows the iPhone's answer.
struct CommandButton: View {
    let title: String
    let systemImage: String
    let cmd: String
    let arg: String?

    @EnvironmentObject var link: PhoneLink
    @State private var busy = false
    @State private var message: String? = nil
    @State private var succeeded = true

    init(title: String, systemImage: String, cmd: String, arg: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.cmd = cmd
        self.arg = arg
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
        link.command(cmd, arg: arg) { ok, text in
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
            CommandButton(title: "For 15 minutes", systemImage: "clock", cmd: "pause", arg: "15")
            CommandButton(title: "For 1 hour", systemImage: "clock", cmd: "pause", arg: "60")
            CommandButton(title: "For 4 hours", systemImage: "clock", cmd: "pause", arg: "240")
        }
        .navigationTitle("Pause sharing")
    }
}

/// Fixed phrases only: the watch sends an id, the iPhone owns the words
/// (same ids as kWatchReplies in watch_snapshot.dart).
struct RepliesView: View {
    @EnvironmentObject var link: PhoneLink

    private let phrases: [(id: String, text: String)] = [
        ("ok", "I'm OK"),
        ("omw", "On my way"),
        ("late", "Running late"),
        ("call", "Please call me"),
        ("thanks", "Thanks"),
    ]

    var body: some View {
        List {
            if let scope = link.snapshot?.scope.name {
                Text("To \(scope == "Everyone" ? "your family" : scope)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(phrases, id: \.id) { phrase in
                CommandButton(title: phrase.text, systemImage: "paperplane.fill",
                              cmd: "reply", arg: phrase.id)
            }
        }
        .navigationTitle("Replies")
    }
}

struct AlertsView: View {
    @EnvironmentObject var link: PhoneLink

    var body: some View {
        let alerts = link.snapshot?.alerts ?? []
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
                    if !alert.note.isEmpty {
                        Text(alert.note).font(.footnote)
                    }
                    Text(agoText(alert.date))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if alert.active {
                        CommandButton(title: "Got it", systemImage: "checkmark", cmd: "ack", arg: alert.id)
                    }
                }
            }
        }
        .navigationTitle("Alerts")
    }
}
