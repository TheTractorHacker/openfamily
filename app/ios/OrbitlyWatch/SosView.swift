import SwiftUI
import WatchKit

/// SOS: press and hold, then a short countdown that can be cancelled. The
/// iPhone sends the alert; if it cannot be reached the watch says so plainly
/// and never pretends the alert went out.
struct SosView: View {
    enum Phase: Equatable {
        case idle
        case counting
        case sending
        case sent(String)
        case failed(String)
        case resolved
    }

    @EnvironmentObject var link: PhoneLink
    @State private var phase: Phase = .idle

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch phase {
                case .idle:
                    idleView
                case .counting:
                    CountdownView(seconds: 5, onCancel: cancel, onDone: send)
                case .sending:
                    ProgressView()
                    Text("Sending SOS")
                        .font(.footnote)
                case .sent(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(Brand.lime)
                    Text("SOS sent")
                        .font(.headline)
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundColor(.secondary)
                    }
                    Text("Your family was notified. Emergency services were NOT contacted.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(Brand.warn)
                    Text("SOS NOT sent")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Text("If it is urgent, call emergency services.")
                        .font(.footnote.bold())
                        .multilineTextAlignment(.center)
                    Button("Try again") { phase = .idle }
                case .resolved:
                    Text("Marked safe.")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("SOS")
    }

    private var idleView: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Brand.sosRed)
                Text("SOS")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: 96, height: 96)
            .onLongPressGesture(minimumDuration: 1.0) {
                WKInterfaceDevice.current().play(.start)
                phase = .counting
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SOS. Double tap and hold to start the countdown.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { phase = .counting }
            Text("Press and hold")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func cancel() {
        WKInterfaceDevice.current().play(.stop)
        phase = .idle
    }

    private func send() {
        phase = .sending
        link.command("sos") { ok, message in
            if ok {
                WKInterfaceDevice.current().play(.success)
                phase = .sent(message)
            } else {
                WKInterfaceDevice.current().play(.failure)
                phase = .failed(message)
            }
        }
    }
}

/// Counts down once per second and calls onDone at zero. It only exists while
/// counting, so its timer stops with it.
struct CountdownView: View {
    let seconds: Int
    let onCancel: () -> Void
    let onDone: () -> Void

    @State private var remaining: Int
    @State private var finished = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(seconds: Int, onCancel: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.seconds = seconds
        self.onCancel = onCancel
        self.onDone = onDone
        _remaining = State(initialValue: seconds)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("\(remaining)")
                .font(.system(size: 54, weight: .bold, design: .rounded))
                .foregroundColor(Brand.sosRed)
            Text("Sending SOS")
                .font(.footnote)
            Button(action: onCancel) {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .tint(Brand.lime)
        }
        .onReceive(ticker) { _ in
            if finished { return }
            if remaining <= 1 {
                finished = true
                remaining = 0
                onDone()
            } else {
                remaining -= 1
                WKInterfaceDevice.current().play(.click)
            }
        }
    }
}
