import SwiftUI

#if canImport(Sparkle)
import Sparkle
import Combine

/// Wraps Sparkle's standard updater so SwiftUI views can drive
/// "Check for Updates…" / automatic background checks. Only compiled
/// when the Sparkle SPM package is present in the project, so the app
/// keeps building before / between Sparkle wiring steps.
///
/// Required Info.plist keys (see ReleaseProcess.md):
///   - `SUFeedURL`         — appcast.xml URL (HTTPS)
///   - `SUPublicEDKey`     — base-64 EdDSA public key from `generate_keys`
///   - `SUEnableAutomaticChecks` — `true` to check on launch + daily
@MainActor
final class UpdateController {
    let standard: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` schedules the periodic check using
        // `SUEnableAutomaticChecks` from Info.plist; the user can also
        // trigger one manually via the menu.
        standard = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { standard.updater }
}

/// SwiftUI button bound to `SPUUpdater.checkForUpdates`. Mirrors
/// Sparkle's documented SwiftUI recipe — exposes `canCheckForUpdates`
/// so the menu item disables itself while a check is in progress.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }
}
#endif
