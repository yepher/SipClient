import SwiftUI

@main
struct SipClientApp: App {
    @StateObject private var appState = AppState()

    #if canImport(Sparkle)
    /// Sparkle updater. Activates automatic checks per `SUEnableAutomaticChecks`
    /// in Info.plist and exposes a `Check for Updates…` menu command.
    private let updateController = UpdateController()
    #endif

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
                .onOpenURL { url in
                    appState.handleIncomingFile(url)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            #if canImport(Sparkle)
            // Slot the standard "Check for Updates…" item into the app
            // menu, right after "About SipClient".
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updateController.updater)
            }
            #endif
        }

        // Pop-out window for the post-call charts. Opened from the
        // wire log via openWindow(id: "callCharts", value: <UUID>);
        // the value picks which CallChartSnapshot in AppState to draw.
        WindowGroup("Call Charts", id: "callCharts", for: UUID.self) { $snapshotID in
            CallChartsWindow(snapshotID: snapshotID)
                .environmentObject(appState)
        }
    }
}
