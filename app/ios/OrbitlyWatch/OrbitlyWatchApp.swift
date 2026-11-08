import SwiftUI

@main
struct OrbitlyWatchApp: App {
    @StateObject private var link = PhoneLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
        }
        // On screen: the iPhone sends every few seconds; wrist down (always-on) about once a
        // minute; in the background only meaningful changes.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: link.setOnScreen(true, ambient: false)
            case .inactive: link.setOnScreen(true, ambient: true)
            default: link.setOnScreen(false, ambient: false)
            }
        }
    }
}
