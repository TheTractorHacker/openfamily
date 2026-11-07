import SwiftUI

@main
struct OrbitlyWatchApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
        }
    }
}
