import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var wireLog: [WireLogEntry] = []
    @Published var callStatus: String = "Idle"
    @Published var callInProgress: Bool = false
    @Published var audioClips: [AudioClip] = []
    @Published var scenarios: [Scenario] = []

    private var currentCall: SIPCall?
    private var currentTask: Task<Void, Never>?

    func appendLog(_ entry: WireLogEntry) {
        wireLog.append(entry)
        if wireLog.count > 5_000 {
            wireLog.removeFirst(wireLog.count - 5_000)
        }
    }

    func clearLog() { wireLog.removeAll() }

    func placeCall(config: SIPCallConfig) {
        guard !callInProgress else { return }
        callInProgress = true
        callStatus = "Starting…"

        let call = SIPCall(config: config)
        currentCall = call

        // Bridge callbacks back to MainActor. Use plain (strong) self capture —
        // SIPCall lifetime is bounded by AppState, and capturing a `let` self
        // avoids the "var captured in concurrent closure" warning that
        // [weak self] would produce here.
        call.onWireLog = { entry in
            Task { @MainActor in
                self.appendLog(entry)
            }
        }
        call.onStatus = { s in
            Task { @MainActor in
                self.callStatus = s
            }
        }

        currentTask = Task.detached(priority: .userInitiated) {
            do {
                try call.run()
                await MainActor.run {
                    self.callStatus = "Ended"
                    self.callInProgress = false
                    self.currentCall = nil
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run {
                    self.callStatus = "Failed: \(msg)"
                    self.callInProgress = false
                    self.currentCall = nil
                    self.appendLog(.init(
                        direction: .sent, kind: .error,
                        summary: "Call failed: \(msg)", detail: nil
                    ))
                }
            }
        }
    }

    func hangup() {
        currentCall?.requestHangup()
    }
}
