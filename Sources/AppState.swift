import Combine
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var wireLog: [WireLogEntry] = []
    @Published var callStatus: String = "Idle"
    @Published var callInProgress: Bool = false
    @Published var callConnected: Bool = false
    @Published var audioClips: [AudioClip] = []
    @Published var scenarios: [Scenario] = []
    @Published var profiles: [DialerProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var selectedScenarioID: UUID?
    @Published var runningScenarioID: UUID?
    @Published var currentScenarioStep: Int?
    @Published var rtpStats: String = ""
    /// Per-call metrics (created at placeCall, kept around for the
    /// final summary). UI binds to this for the in-call timing/jitter
    /// display.
    @Published var callMetrics: CallMetrics?
    /// A `.sipcall` file the user just opened — drives the import sheet.
    @Published var pendingImport: PendingProfileImport?

    /// UDP listener for inbound calls. Off by default; user toggles it
    /// from the Inbound tab.
    let inboundListener = InboundListener()
    /// Set when a new INVITE arrives. Drives the Answer / Reject prompt.
    @Published var pendingInbound: InboundCall?
    /// Active inbound call — set on Answer, cleared when the call ends.
    private var currentInboundCall: InboundCall?

    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []

    let audioEngine = AudioEngine()

    /// Shared mic→RTP buffer. The mic tap writes here, the RTP send loop
    /// reads from here. Empty → silence is sent.
    /// Sized at 1 s × 48 kHz so any codec rate (8/16/48 kHz) fits.
    let callMicBuffer = FrameBuffer(maxSeconds: 1.0, sampleRate: 48000)

    /// The active call's RTP session, exposed so scenarios can send DTMF.
    private var currentRTPSession: RTPSession?

    private var currentCall: SIPCall?
    private var currentTask: Task<Void, Never>?
    private var rtpStatsTask: Task<Void, Never>?
    private var scenarioTask: Task<Void, Never>?

    /// Forward audioEngine's @Published changes (level meters, mode) into
    /// AppState's own publisher so any view bound to `appState` sees them.
    private var engineSubscription: AnyCancellable?
    private var inboundListenerSubscription: AnyCancellable?

    /// CoreAudio property listener that fires when the system device
    /// list changes (e.g. AirPods connect, USB mic plug/unplug).
    private var deviceListObserver: DeviceListObserver?

    init() {
        loadAudioLibrary()
        loadProfiles()
        loadScenarios()
        refreshAudioDevices()

        // Republish audioEngine changes so views observing appState pick up
        // VU meter updates and mode transitions.
        engineSubscription = audioEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Same for the inbound listener so the Inbound tab's listening /
        // status fields refresh.
        inboundListenerSubscription = inboundListener.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // Surface audio engine diagnostics in the wire log.
        audioEngine.onDiagnostic = { [weak self] msg in
            Task { @MainActor in
                self?.appendLog(.init(direction: .sent, kind: .info,
                                      summary: "audio: \(msg)"))
            }
        }

        // Auto-refresh the device dropdowns when the system device list
        // changes (AirPods connect, USB mic plug/unplug, etc).
        deviceListObserver = AudioDevices.observeDeviceListChanges { [weak self] in
            Task { @MainActor in
                self?.refreshAudioDevices()
            }
        }
    }

    // MARK: - App support directory

    var appSupportDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("SipClient", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Wire log

    func appendLog(_ entry: WireLogEntry) {
        wireLog.append(entry)
        if wireLog.count > 5_000 {
            wireLog.removeFirst(wireLog.count - 5_000)
        }
    }

    func clearLog() { wireLog.removeAll() }

    // MARK: - Outbound call

    func placeCall(config: SIPCallConfig) {
        guard !callInProgress else { return }
        callInProgress = true
        callStatus = "Starting…"

        let metrics = CallMetrics()
        callMetrics = metrics

        let call = SIPCall(config: config)
        currentCall = call

        call.onWireLog = { entry in
            Task { @MainActor in self.appendLog(entry) }
        }
        call.onStatus = { s in
            Task { @MainActor in self.callStatus = s }
        }
        call.onInviteSent = {
            Task { @MainActor in metrics.recordInvite() }
        }
        call.onProvisional = { status in
            Task { @MainActor in metrics.recordResponse(status: status) }
        }
        call.onAnswered = {
            Task { @MainActor in metrics.recordResponse(status: 200) }
        }
        call.onMediaReady = { rtpSession in
            Task { @MainActor in self.attachAudio(to: rtpSession) }
        }
        call.onMediaEnd = {
            Task { @MainActor in self.detachAudio() }
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
                    self.appendLog(.init(direction: .sent, kind: .error,
                                         summary: "Call failed: \(msg)"))
                }
            }
        }
    }

    func hangup() {
        if let inbound = currentInboundCall, !inbound.ended {
            try? inbound.hangup()
            return
        }
        currentCall?.requestHangup()
    }

    // MARK: - Inbound call

    /// Hook the listener into AppState and start it. Logs failures.
    func startInboundListener() {
        inboundListener.onIncomingInvite = { [weak self] req, host, port in
            Task { @MainActor in
                self?.handleIncomingInvite(req, sourceHost: host, sourcePort: port)
            }
        }
        inboundListener.onInDialogRequest = { [weak self] req, host, port in
            Task { @MainActor in
                _ = self?.currentInboundCall?.handleInDialogRequest(
                    req, from: host, port: port
                )
            }
        }
        inboundListener.onWireLog = { [weak self] entry in
            Task { @MainActor in self?.appendLog(entry) }
        }
        do {
            try inboundListener.start()
            appendLog(.init(
                direction: .sent, kind: .info,
                summary: "Inbound listener started on port \(inboundListener.localPort)"
            ))
        } catch {
            inboundListener.lastError = error.localizedDescription
            appendLog(.init(
                direction: .sent, kind: .error,
                summary: "Failed to start inbound listener: \(error.localizedDescription)"
            ))
        }
    }

    func stopInboundListener() {
        inboundListener.stop()
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "Inbound listener stopped"))
    }

    /// Called from the listener when a fresh INVITE arrives. We auto-
    /// reject with 486 Busy if there's already a call in flight; else
    /// stage the call and kick out 100 Trying / 180 Ringing immediately
    /// while the user decides.
    private func handleIncomingInvite(_ req: SIPRequest,
                                      sourceHost: String, sourcePort: UInt16) {
        guard let socket = inboundListener.sharedSocket else { return }

        if callInProgress || pendingInbound != nil || currentInboundCall != nil {
            // Build a quick 486 directly without InboundCall machinery.
            let busy = quickRejectResponse(for: req, code: 486, reason: "Busy Here")
            try? socket.send(Data(busy.utf8), to: sourceHost, port: sourcePort)
            appendLog(.init(direction: .sent, kind: .info,
                            summary: "→ 486 Busy Here (already in a call)"))
            return
        }

        // Reuse the listener's pre-allocated, STUN-discovered RTP socket.
        // This guarantees the address we put in our SDP matches the NAT
        // mapping the peer will hit.
        guard let rtpSocket = inboundListener.sharedRTPSocket else {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "RTP socket missing — listener not started?"))
            return
        }

        let publicSIPHost = inboundListener.publicHost.isEmpty
            ? inboundListener.detectedLocalIP
            : inboundListener.publicHost
        let publicSIPPort: UInt16 = inboundListener.publicSIPPort != 0
            ? inboundListener.publicSIPPort
            : inboundListener.localPort
        // RTP host: prefer STUN-discovered public IP, fall back to
        // user-supplied publicHost or local IP.
        let publicRTPHost: String
        if !inboundListener.stunRTPHost.isEmpty {
            publicRTPHost = inboundListener.stunRTPHost
        } else if !inboundListener.publicHost.isEmpty {
            publicRTPHost = inboundListener.publicHost
        } else {
            publicRTPHost = inboundListener.detectedLocalIP
        }
        let publicRTPPort: UInt16
        if inboundListener.stunRTPPort != 0 {
            publicRTPPort = inboundListener.stunRTPPort
        } else if inboundListener.publicRTPPort != 0 {
            publicRTPPort = inboundListener.publicRTPPort
        } else {
            publicRTPPort = rtpSocket.localPort
        }

        let call = InboundCall(
            invite: req,
            sourceHost: sourceHost, sourcePort: sourcePort,
            socket: socket, rtpSocket: rtpSocket,
            publicSIPHost: publicSIPHost, publicSIPPort: publicSIPPort,
            publicRTPHost: publicRTPHost, publicRTPPort: publicRTPPort
        )
        call.onWireLog = { [weak self] entry in
            Task { @MainActor in self?.appendLog(entry) }
        }
        call.onAnswered = { [weak self] rtp in
            Task { @MainActor in self?.attachAudio(to: rtp) }
        }
        call.onEnded = { [weak self] in
            Task { @MainActor in self?.handleInboundEnded() }
        }

        // Polite UAS: send 100 Trying then 180 Ringing immediately so
        // the peer doesn't retransmit while the user thinks.
        try? call.sendProvisional(code: 100, reason: "Trying")
        try? call.sendProvisional(code: 180, reason: "Ringing")

        currentInboundCall = call
        pendingInbound = call
        callStatus = "Inbound call from \(call.fromDisplay.isEmpty ? call.fromURI : call.fromDisplay)"
    }

    func answerInboundCall() {
        guard let call = currentInboundCall else { return }
        do {
            try call.answer()
            pendingInbound = nil
            callInProgress = true
            callStatus = "In Call (inbound)"
        } catch {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Answer failed: \(error.localizedDescription)"))
        }
    }

    func rejectInboundCall(code: Int = 486, reason: String = "Busy Here") {
        guard let call = currentInboundCall else { return }
        try? call.reject(code: code, reason: reason)
        pendingInbound = nil
        currentInboundCall = nil
        callStatus = "Rejected"
    }

    private func handleInboundEnded() {
        if currentRTPSession != nil {
            detachAudio()
        }
        callInProgress = false
        callConnected = false
        currentInboundCall = nil
        pendingInbound = nil
        callStatus = "Ended"
    }

    /// Build a minimal SIP response without the InboundCall state — used
    /// for the auto-busy reject when no call slot is available.
    private func quickRejectResponse(for req: SIPRequest,
                                     code: Int, reason: String) -> String {
        let via = req.firstHeader("via") ?? ""
        let from = req.firstHeader("from") ?? ""
        var to = req.firstHeader("to") ?? ""
        if SIPHeaders.tagParam(to) == nil {
            to += ";tag=\(SIPTokens.tag())"
        }
        let callid = req.firstHeader("call-id") ?? ""
        let cseq = req.firstHeader("cseq") ?? "1 INVITE"
        return """
        SIP/2.0 \(code) \(reason)\r
        Via: \(via)\r
        From: \(from)\r
        To: \(to)\r
        Call-ID: \(callid)\r
        CSeq: \(cseq)\r
        Content-Length: 0\r
        \r

        """
    }

    // MARK: - Audio wiring during a call

    private func attachAudio(to rtp: RTPSession) {
        rtp.micBuffer = callMicBuffer
        currentRTPSession = rtp
        callConnected = true
        callMetrics?.setPtime(rtp.ptime)

        Task { @MainActor in
            // Start the engine with the mic tap installed BEFORE we let
            // RTP samples reach the playback path. If we let the player
            // start first (in output-only mode) and then try to add the
            // mic tap, CoreAudio rebuilds the graph and the receive path
            // goes silent — the exact bug previously seen at the moment
            // mic permission was granted.
            let ok = await AudioEngine.requestMicAuthorization()
            if !ok {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Microphone access denied — sending silence. Enable SIP Client in System Settings → Privacy & Security → Microphone."))
            } else {
                do {
                    try self.audioEngine.startCallMode(micBuffer: self.callMicBuffer,
                                                       codec: rtp.codec)
                    self.appendLog(.init(direction: .sent, kind: .info,
                                         summary: "Mic → RTP started"))
                } catch {
                    self.appendLog(.init(direction: .sent, kind: .error,
                                         summary: "Mic start failed: \(error.localizedDescription)"))
                }
            }

            // Now wire up RTP receive → playback. By the time the first
            // RTP packet hits this callback, the engine is already
            // running with both input and output configured.
            rtp.onPlaybackPCM = { [weak self] samples in
                guard let self else { return }
                self.audioEngine.levelMeter.recordRecv(samples)
                // Compute peak for first-audio detection + jitter math.
                var peak: Int32 = 0
                for s in samples {
                    let v = Int32(s)
                    let absV = v < 0 ? -v : v
                    if absV > peak { peak = absV }
                }
                Task { @MainActor in
                    self.callMetrics?.recordPacket(peak: peak)
                    self.audioEngine.enqueuePlayback(samples: samples)
                }
            }
        }

        rtpStatsTask = Task.detached { [weak rtp] in
            while !Task.isCancelled, let r = rtp {
                let sent = r.packetsSent
                let recv = r.packetsReceived
                let expected = r.packetsExpected
                let lost = r.packetsLost
                let lossPct: Double = expected > 0
                    ? Double(max(Int64(0), lost)) / Double(expected) * 100
                    : 0
                let s: String
                if expected > 0 {
                    s = String(
                        format: "RTP sent=%llu recv=%llu lost=%lld (%.2f%%)",
                        sent, recv, lost, lossPct
                    )
                } else {
                    s = "RTP sent=\(sent) recv=\(recv)"
                }
                await MainActor.run {
                    self.rtpStats = s
                    self.callMetrics?.updateLossCounts(
                        expected: expected,
                        received: recv,
                        lost: lost
                    )
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func detachAudio() {
        if let metrics = callMetrics {
            appendLog(.init(direction: .sent, kind: .info,
                            summary: metrics.summaryLine,
                            detail: metrics.summaryDetail))
        }
        callMicBuffer.clear()
        audioEngine.stopCallMode()
        rtpStatsTask?.cancel()
        rtpStatsTask = nil
        currentRTPSession = nil
        callConnected = false
    }

    // MARK: - Audio devices

    func refreshAudioDevices() {
        inputDevices = AudioDevices.list(input: true)
        outputDevices = AudioDevices.list(input: false)
    }

    var selectedInputDeviceID: AudioDeviceID {
        audioEngine.currentInputDeviceID
    }
    var selectedOutputDeviceID: AudioDeviceID {
        audioEngine.currentOutputDeviceID
    }

    func setInputDevice(_ id: AudioDeviceID) {
        audioEngine.setInputDevice(id)
    }
    func setOutputDevice(_ id: AudioDeviceID) {
        audioEngine.setOutputDevice(id)
    }

    var micMuted: Bool { audioEngine.micMuted }
    func toggleMicMuted() {
        audioEngine.toggleMicMuted()
        appendLog(.init(direction: .sent, kind: .info,
                        summary: audioEngine.micMuted ? "Mic muted" : "Mic unmuted"))
    }

    /// Send DTMF digits over the active call as RFC 4733 events.
    func sendDTMF(_ digits: String) {
        guard let rtp = currentRTPSession else {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Cannot send DTMF: no active call"))
            return
        }
        Task.detached {
            await rtp.sendDTMFDigits(digits)
        }
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "DTMF: \(digits)"))
    }

    // MARK: - Profiles

    private var profilesURL: URL {
        appSupportDir.appendingPathComponent("profiles.json")
    }

    func loadProfiles() {
        if let data = try? Data(contentsOf: profilesURL),
           let list = try? JSONDecoder().decode([DialerProfile].self, from: data) {
            profiles = list
        }
        // Migrate from old @AppStorage values on first launch.
        if profiles.isEmpty {
            let defaults = UserDefaults.standard
            let host = defaults.string(forKey: "dialer.sipHost") ?? ""
            let to = defaults.string(forKey: "dialer.toURI") ?? ""
            if !host.isEmpty || !to.isEmpty {
                var p = DialerProfile(name: "Default")
                p.sipHost = host
                p.toURI = to
                if let s = defaults.string(forKey: "dialer.sipPort"),
                   let v = UInt16(s) { p.sipPort = v }
                p.fromUser = defaults.string(forKey: "dialer.fromUser") ?? p.fromUser
                p.fromDisplay = defaults.string(forKey: "dialer.fromDisplay") ?? p.fromDisplay
                p.authUser = defaults.string(forKey: "dialer.authUser") ?? ""
                p.useSTUN = defaults.object(forKey: "dialer.useSTUN") as? Bool ?? true
                p.stunServer = defaults.string(forKey: "dialer.stunServer") ?? ""
                if let s = defaults.string(forKey: "dialer.localSIPPort"),
                   let v = UInt16(s) { p.localSIPPort = v }
                if let s = defaults.string(forKey: "dialer.localRTPPort"),
                   let v = UInt16(s) { p.localRTPPort = v }
                if let d = defaults.object(forKey: "dialer.callDuration") as? Double {
                    p.callDuration = d
                }
                profiles = [p]
                saveProfiles()
            }
        }
        // Restore last selection
        if let s = UserDefaults.standard.string(forKey: "dialer.selectedProfileID"),
           let id = UUID(uuidString: s),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        } else {
            selectedProfileID = profiles.first?.id
        }
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
    }

    func selectProfile(_ id: UUID?) {
        selectedProfileID = id
        if let id { UserDefaults.standard.set(id.uuidString, forKey: "dialer.selectedProfileID") }
    }

    /// Insert if new, replace if existing. Saves immediately.
    func upsertProfile(_ profile: DialerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        saveProfiles()
    }

    func profile(id: UUID?) -> DialerProfile? {
        guard let id else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    // MARK: - Scenarios

    private var scenariosURL: URL {
        appSupportDir.appendingPathComponent("scenarios.json")
    }

    func loadScenarios() {
        if let data = try? Data(contentsOf: scenariosURL),
           let list = try? JSONDecoder().decode([Scenario].self, from: data) {
            scenarios = list
        }
        if let s = UserDefaults.standard.string(forKey: "scenarios.selectedID"),
           let id = UUID(uuidString: s),
           scenarios.contains(where: { $0.id == id }) {
            selectedScenarioID = id
        } else {
            selectedScenarioID = scenarios.first?.id
        }
    }

    func saveScenarios() {
        if let data = try? JSONEncoder().encode(scenarios) {
            try? data.write(to: scenariosURL, options: .atomic)
        }
    }

    func selectScenario(_ id: UUID?) {
        selectedScenarioID = id
        if let id { UserDefaults.standard.set(id.uuidString, forKey: "scenarios.selectedID") }
    }

    func upsertScenario(_ scenario: Scenario) {
        if let idx = scenarios.firstIndex(where: { $0.id == scenario.id }) {
            scenarios[idx] = scenario
        } else {
            scenarios.append(scenario)
        }
        saveScenarios()
    }

    func deleteScenario(id: UUID) {
        scenarios.removeAll { $0.id == id }
        if selectedScenarioID == id {
            selectedScenarioID = scenarios.first?.id
        }
        saveScenarios()
    }

    func scenario(id: UUID?) -> Scenario? {
        guard let id else { return nil }
        return scenarios.first(where: { $0.id == id })
    }

    /// Run the scenario. If it has a profile, places that call first and
    /// runs steps after answer; otherwise runs against the active call.
    func runScenario(_ scenario: Scenario, authPassword: String = "") {
        guard runningScenarioID == nil else { return }
        runningScenarioID = scenario.id
        currentScenarioStep = nil
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "Running scenario: \(scenario.name)"))

        scenarioTask = Task { [scenario] in
            defer {
                Task { @MainActor in
                    self.runningScenarioID = nil
                    self.currentScenarioStep = nil
                    self.appendLog(.init(direction: .sent, kind: .info,
                                         summary: "Scenario finished: \(scenario.name)"))
                }
            }

            // Place call from profile if specified.
            if let profileID = scenario.profileID,
               let profile = self.profile(id: profileID),
               !self.callInProgress {
                let cfg = profile.callConfig(authPassword: authPassword)
                self.placeCall(config: cfg)
            }

            for (idx, step) in scenario.steps.enumerated() {
                if Task.isCancelled { return }
                self.currentScenarioStep = idx
                await self.executeStep(step)
            }
        }
    }

    func cancelScenario() {
        scenarioTask?.cancel()
        scenarioTask = nil
        runningScenarioID = nil
        currentScenarioStep = nil
    }

    private func executeStep(_ step: ScenarioStep) async {
        switch step {
        case .waitForAnswer(let timeout):
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Task.isCancelled { return }
                if callConnected { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "waitForAnswer timed out after \(Int(timeout))s"))
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        case .playClip(let clipID):
            if let clip = audioClips.first(where: { $0.id == clipID }) {
                playClipIntoCall(clip)
                // Wait for the clip to finish so subsequent steps run after it.
                let nanos = UInt64(clip.durationSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            } else {
                appendLog(.init(direction: .sent, kind: .error,
                                summary: "Clip not found in scenario"))
            }
        case .sendDTMF(let digits):
            guard let rtp = currentRTPSession else {
                appendLog(.init(direction: .sent, kind: .error,
                                summary: "Cannot send DTMF: no active call"))
                return
            }
            await rtp.sendDTMFDigits(digits)
            appendLog(.init(direction: .sent, kind: .info,
                            summary: "DTMF: \(digits)"))
        case .hangup:
            hangup()
        }
    }

    // MARK: - Audio Library

    /// Where audio clips are persisted on disk.
    var clipsDirectory: URL {
        let dir = appSupportDir.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var libraryIndexURL: URL {
        clipsDirectory.appendingPathComponent("library.json")
    }

    func loadAudioLibrary() {
        guard let data = try? Data(contentsOf: libraryIndexURL),
              let clips = try? JSONDecoder().decode([AudioClip].self, from: data)
        else { return }
        // Keep only clips whose file still exists
        audioClips = clips.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func saveAudioLibrary() {
        if let data = try? JSONEncoder().encode(audioClips) {
            try? data.write(to: libraryIndexURL, options: .atomic)
        }
    }

    /// Save 8 kHz mono Int16 samples as a WAV in the library directory and
    /// add an entry for it.
    func addClip(samples: [Int16], name: String) throws {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = clipsDirectory.appendingPathComponent("\(UUID().uuidString)_\(safe).wav")
        try WAVFile.write(samples: samples, to: url)
        let duration = Double(samples.count) / 8000.0
        let clip = AudioClip(name: name, fileURL: url, durationSeconds: duration)
        audioClips.append(clip)
        saveAudioLibrary()
    }

    /// Import an existing WAV — resampled if needed (we only handle 8 kHz mono
    /// for now; reject otherwise so we don't silently misplay).
    func importClip(from sourceURL: URL, name: String) throws {
        let loaded = try WAVFile.read(url: sourceURL)
        let samples: [Int16]
        if loaded.sampleRate == 8000 && loaded.channels == 1 {
            samples = loaded.samples
        } else if loaded.channels == 1 && loaded.sampleRate > 0 {
            // Linear resample (nearest-neighbor) to 8 kHz. Crude but fine for clips.
            let ratio = Double(loaded.sampleRate) / 8000.0
            let outCount = Int(Double(loaded.samples.count) / ratio)
            var out = [Int16](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let src = Int(Double(i) * ratio)
                if src < loaded.samples.count { out[i] = loaded.samples[src] }
            }
            samples = out
        } else {
            throw NSError(domain: "AudioLibrary", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Only mono WAV files are supported (got \(loaded.channels) channels)."
            ])
        }
        try addClip(samples: samples, name: name)
    }

    func deleteClip(_ clip: AudioClip) {
        try? FileManager.default.removeItem(at: clip.fileURL)
        audioClips.removeAll { $0.id == clip.id }
        saveAudioLibrary()
    }

    func renameClip(_ clip: AudioClip, to newName: String) {
        guard let idx = audioClips.firstIndex(where: { $0.id == clip.id }) else { return }
        audioClips[idx].name = newName
        saveAudioLibrary()
    }

    /// Play a clip through the speakers (for previewing).
    func previewClip(_ clip: AudioClip) {
        guard let loaded = try? WAVFile.read(url: clip.fileURL) else { return }
        audioEngine.enqueuePlayback(samples: loaded.samples)
    }

    /// Play a clip into the active call by feeding samples into the
    /// shared mic buffer. Mic continues to run; the clip is mixed in by
    /// taking priority — actually we just append samples, which means
    /// the clip will play *between* mic frames if mic buffer drains. For
    /// a clean send, you'd want a dedicated source-switch; this is fine
    /// for the simple case where the user pauses talking before pressing.
    func playClipIntoCall(_ clip: AudioClip) {
        guard callInProgress, let loaded = try? WAVFile.read(url: clip.fileURL) else { return }
        callMicBuffer.write(loaded.samples)
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "Queued clip “\(clip.name)” into call (\(loaded.samples.count) samples)"))
    }

    // MARK: - Recording

    func startRecording() {
        Task { @MainActor in
            let ok = await AudioEngine.requestMicAuthorization()
            guard ok else {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Microphone access denied"))
                return
            }
            do {
                try self.audioEngine.startRecordMode()
            } catch {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Record start failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Stops recording and saves the captured samples as a new clip.
    func stopRecordingAndSave(name: String) {
        let samples = audioEngine.stopRecordMode()
        guard !samples.isEmpty else {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Recording produced no samples"))
            return
        }
        do {
            try addClip(samples: samples, name: name)
        } catch {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Failed to save clip: \(error.localizedDescription)"))
        }
    }

    // MARK: - Profile import (from double-click)

    /// Called when the user double-clicks a `.sipcall` file in Finder.
    /// Reads the file off-disk and stages a `PendingProfileImport`,
    /// which the UI sheet observes.
    func handleIncomingFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "sipcall" else { return }
        // The OS may hand us a security-scoped URL.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let profile = try SIPCallExport.decode(data: data)
            pendingImport = PendingProfileImport(
                sourceURL: url,
                profile: profile
            )
        } catch {
            appendLog(.init(
                direction: .sent, kind: .error,
                summary: "Failed to read \(url.lastPathComponent)",
                detail: error.localizedDescription
            ))
        }
    }

    /// Commit a pending import after the user has confirmed (and possibly
    /// renamed) it. The profile keeps its original UUID, so re-importing
    /// the same file updates the existing entry instead of creating a copy.
    func confirmPendingImport(profile: DialerProfile) {
        upsertProfile(profile)
        selectProfile(profile.id)
        pendingImport = nil
        appendLog(.init(
            direction: .sent, kind: .info,
            summary: "Imported profile “\(profile.name)”"
        ))
    }

    func cancelPendingImport() {
        pendingImport = nil
    }
}

/// Holds an inbound `.sipcall` file the user has opened, until they
/// confirm (or cancel) the import in the sheet.
struct PendingProfileImport: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let profile: DialerProfile
}
