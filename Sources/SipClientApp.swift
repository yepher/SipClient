import SwiftUI

@main
struct SipClientApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Trigger the TCC prompt at launch so the user isn't asked
                    // mid-call. AVAudioEngine creates its inputNode when the
                    // process is already authorized, avoiding a half-configured
                    // input AU on the first call after a fresh grant.
                    _ = await AudioEngine.requestMicAuthorization()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
