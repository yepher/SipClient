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

    /// The dialer form's live settings, including edits the user hasn't
    /// saved yet. DialerView mirrors its draft here on every change.
    ///
    /// Outbound calls never needed this — they're placed straight from
    /// the form. Inbound calls and scenarios did: they used to read the
    /// profile as last written to disk, so unsaved edits silently didn't
    /// apply. Anything that configures a call from a profile should go
    /// through `profileWithLiveEdits(id:)` rather than `profile(id:)`.
    ///
    /// Deliberately not `@Published`: nothing renders from it, and it is
    /// rewritten on every keystroke in the dialer form. Publishing it
    /// would fire `objectWillChange` for every view bound to AppState —
    /// wire log, charts, in-call view — on each character typed.
    private(set) var draftProfile: DialerProfile?
    @Published var selectedScenarioID: UUID?
    @Published var runningScenarioID: UUID?
    @Published var currentScenarioStep: Int?
    /// 1-based call number within a repeated scenario run.
    @Published var currentScenarioIteration: Int?
    /// The latest scenario run's results — live while it runs, kept after.
    @Published private(set) var scenarioRun: ScenarioRunReport?
    /// Where `scenarioRun` is being written (a .txt; a .csv sits beside it).
    @Published private(set) var scenarioRunReportURL: URL?
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

    /// Post-call chart snapshots, keyed by snapshot ID. The wire log's
    /// "View In Call Chart" entry references one of these. Capped at
    /// the most recent N to bound memory.
    @Published private(set) var callCharts: [UUID: CallChartSnapshot] = [:]
    /// Insertion order so we can evict oldest when the cap is reached.
    private var callChartOrder: [UUID] = []
    private let maxCallCharts = 20

    let audioEngine = AudioEngine()

    /// Shared mic→RTP buffer. The mic tap writes here, the RTP send loop
    /// reads from here. Empty → silence is sent.
    /// Sized at 1 s × 48 kHz so any codec rate (8/16/48 kHz) fits.
    let callMicBuffer = FrameBuffer(maxSeconds: 1.0, sampleRate: 48000)

    /// Prompts (clips, synthesized speech) to send, already resampled to
    /// the call's codec rate. Takes priority over the mic in the RTP send
    /// loop. Sized generously: a prompt is written in one go.
    let callPromptBuffer = FrameBuffer(maxSeconds: 120, sampleRate: 48000)

    /// The active call's RTP session, exposed so scenarios can send DTMF.
    private var currentRTPSession: RTPSession?

    /// Far-end speech detector for the active call. Scenarios read it to
    /// decide whether the far end was heard.
    private var farEndSpeech: SpeechActivityMonitor?
    /// Status and `X-` headers of the active outbound call's last final
    /// response to INVITE.
    private var lastFinalResponse: (status: Int, headers: [String: String])?
    /// Set while a scenario that ignores the mic is running.
    private var scenarioIgnoresMic = false
    /// Synthesized prompts, keyed by text and sample rate, so a 100-call
    /// run synthesizes each phrase once.
    private var synthesizedPrompts: [String: [Int16]] = [:]

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

    /// Profile setting captured at placeCall — whether muting should
    /// still emit comfort-silence RTP. False ⇒ muting hard-stops the
    /// RTP send loop, which is useful for testing the peer's media
    /// timeout behaviour.
    private var currentSendSilenceWhileMuted: Bool = true

    /// Profile settings captured at placeCall (outbound) or from
    /// `profileWithLiveEdits` at INVITE time (inbound), for the
    /// receive-side jitter buffer.
    private var currentUseJitterBuffer: Bool = false
    private var currentJitterTargetMs: Int = 80
    /// Active jitter buffer for the in-flight call (nil when disabled).
    private var jitterBuffer: JitterBuffer?

    /// Stereo recorder for the in-flight call (nil when not recording).
    private var callRecorder: CallRecorder?
    /// True once the user asks to record, even before a call exists — the
    /// recorder itself can't start until media attaches and we know the
    /// negotiated sample rate, so arming lets you capture from the very
    /// first packet instead of missing the start of the call.
    @Published private(set) var callRecordingArmed = false
    /// File currently being written, for the UI to show and reveal.
    @Published private(set) var callRecordingURL: URL?
    /// The most recently finished recording, carried into the call chart
    /// snapshot so the charts can plot and play it back.
    private var lastFinishedRecording: (url: URL, startedAt: Date)?

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

    func clearLog() {
        wireLog.removeAll()
        callCharts.removeAll()
        callChartOrder.removeAll()
    }

    func callChart(id: UUID) -> CallChartSnapshot? {
        callCharts[id]
    }

    private func storeCallChart(_ snapshot: CallChartSnapshot) {
        callCharts[snapshot.id] = snapshot
        callChartOrder.append(snapshot.id)
        while callChartOrder.count > maxCallCharts {
            let evict = callChartOrder.removeFirst()
            callCharts.removeValue(forKey: evict)
        }
    }

    private func formatChartDuration(_ samples: [ArrivalSample]) -> String {
        guard let first = samples.first?.at, let last = samples.last?.at else {
            return "0.0 s"
        }
        let secs = last.timeIntervalSince(first)
        return String(format: "%.1f s", secs)
    }

    // MARK: - Outbound call

    /// Returns the new call's SIP Call-ID, or nil if a call is already up.
    @discardableResult
    func placeCall(config: SIPCallConfig) -> String? {
        guard !callInProgress else { return nil }
        callInProgress = true
        callStatus = "Starting…"
        currentSendSilenceWhileMuted = config.sendSilenceWhileMuted
        currentUseJitterBuffer = config.useJitterBuffer
        currentJitterTargetMs = config.jitterBufferTargetMs

        let metrics = CallMetrics()
        callMetrics = metrics

        let call = SIPCall(config: config)
        currentCall = call
        farEndSpeech = nil
        lastFinalResponse = nil

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
        call.onFinalResponse = { resp in
            var xHeaders: [String: String] = [:]
            for (name, values) in resp.headers where name.hasPrefix("x-") {
                xHeaders[name] = values.first ?? ""
            }
            Task { @MainActor in
                self.lastFinalResponse = (resp.statusCode, xHeaders)
            }
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
        return call.callID
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
        inboundListener.onIncomingInvite = { [weak self] req, responder in
            Task { @MainActor in
                self?.handleIncomingInvite(req, responder: responder)
            }
        }
        inboundListener.onInDialogRequest = { [weak self] req, responder in
            Task { @MainActor in
                _ = self?.currentInboundCall?.handleInDialogRequest(
                    req, responder: responder
                )
            }
        }
        inboundListener.onWireLog = { [weak self] entry in
            Task { @MainActor in self?.appendLog(entry) }
        }
        inboundListener.sshOnLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(.init(direction: .sent, kind: .info,
                                      summary: "ssh: \(message)"))
            }
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
                                      responder: @escaping InboundResponder) {
        if callInProgress || pendingInbound != nil || currentInboundCall != nil {
            // Build a quick 486 directly without InboundCall machinery.
            let busy = quickRejectResponse(for: req, code: 486, reason: "Busy Here")
            responder(Data(busy.utf8))
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

        // Inbound calls never pass through placeCall, so seed the
        // media settings from the selected profile here — including any
        // edits the user has made but not saved.
        if let p = profileWithLiveEdits(id: selectedProfileID) {
            currentSendSilenceWhileMuted = p.sendSilenceWhileMuted
            currentUseJitterBuffer = p.useJitterBuffer
            currentJitterTargetMs = max(20, min(500, p.jitterBufferTargetMs))
        }

        let call = InboundCall(
            invite: req,
            responder: responder,
            rtpSocket: rtpSocket,
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
        callPromptBuffer.clear()
        rtp.promptBuffer = callPromptBuffer
        rtp.ignoreMic = scenarioIgnoresMic
        let speech = SpeechActivityMonitor()
        farEndSpeech = speech
        let recvRate = rtp.codec.inputSampleRate
        currentRTPSession = rtp
        callConnected = true
        callMetrics?.setPtime(rtp.ptime)

        // Sync the new session's send-suppress flag to the current
        // (muted, sendSilenceWhileMuted) state. Otherwise, if the user
        // had already muted before the call connected (or if the state
        // was set by syncFromSelection / handleIncomingInvite before the
        // RTPSession existed), the loop would start in send-silence mode
        // even when "send silence while muted" is off.
        applySuppressSendForCurrentMuteState()

        // If the user armed recording before the call connected, start it
        // now — this is the first moment we know the negotiated codec, and
        // therefore the sample rate to record at.
        if callRecordingArmed { beginCallRecording(on: rtp) }

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
            //
            // Two paths from here:
            //   (a) jitter buffer disabled: arrival drives playback
            //       directly (legacy behaviour — speaker FIFO smooths
            //       only what the AudioQueue's 4×20 ms preroll absorbs).
            //   (b) jitter buffer enabled: arrival inserts into the JB,
            //       and a steady ptime-cadenced ticker pulls reordered /
            //       PLC'd frames into the speaker.
            // Level meter + CallMetrics always run on arrival so that
            // the jitter chart reflects network timing, not playout.
            if self.currentUseJitterBuffer {
                let jb = JitterBuffer(codec: rtp.codec,
                                      ptimeMs: rtp.ptime,
                                      targetMs: self.currentJitterTargetMs)
                jb.onFrame = { [weak self] frame in
                    Task { @MainActor in
                        self?.deliverPlayback(frame)
                    }
                }
                jb.start()
                self.jitterBuffer = jb
                self.appendLog(.init(direction: .received, kind: .info,
                    summary: "Jitter buffer enabled "
                           + "(target \(self.currentJitterTargetMs) ms, "
                           + "ptime \(rtp.ptime) ms)"))
                rtp.onPlaybackPCM = { [weak self, weak jb] samples, seq, ts, arrivedAt in
                    guard let self else { return }
                    speech.feed(samples, sampleRate: recvRate, at: arrivedAt)
                    self.audioEngine.levelMeter.recordRecv(samples)
                    var peak: Int32 = 0
                    for s in samples {
                        let v = Int32(s)
                        let absV = v < 0 ? -v : v
                        if absV > peak { peak = absV }
                    }
                    Task { @MainActor in
                        self.callMetrics?.recordPacket(peak: peak, at: arrivedAt)
                    }
                    jb?.insert(samples: samples, seq: seq,
                               timestamp: ts, arrivedAt: arrivedAt)
                }
            } else {
                rtp.onPlaybackPCM = { [weak self] samples, _, _, arrivedAt in
                    guard let self else { return }
                    speech.feed(samples, sampleRate: recvRate, at: arrivedAt)
                    self.audioEngine.levelMeter.recordRecv(samples)
                    var peak: Int32 = 0
                    for s in samples {
                        let v = Int32(s)
                        let absV = v < 0 ? -v : v
                        if absV > peak { peak = absV }
                    }
                    Task { @MainActor in
                        self.callMetrics?.recordPacket(peak: peak, at: arrivedAt)
                        self.deliverPlayback(samples)
                    }
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

    /// Everything the far end sends reaches the speaker through here, so
    /// it is also the one place the recorder needs to tap. Whether the
    /// jitter buffer is in the path or not, this is what was heard.
    private func deliverPlayback(_ samples: [Int16]) {
        callRecorder?.appendFar(samples)
        audioEngine.enqueuePlayback(samples: samples)
    }

    // MARK: - Call recording

    /// Where call recordings are written.
    var recordingsDirectory: URL {
        let dir = appSupportDir.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Arm/disarm recording. Armed before a call, it starts as soon as
    /// media attaches; armed during one, it starts immediately.
    func toggleCallRecording() {
        if callRecordingArmed {
            stopCallRecording()
        } else {
            callRecordingArmed = true
            if let rtp = currentRTPSession {
                beginCallRecording(on: rtp)
            } else {
                appendLog(.init(direction: .sent, kind: .info,
                                summary: "Recording armed — starts when the call connects"))
            }
        }
    }

    /// Open the file and start capturing. Called from `attachAudio` (or
    /// directly if armed mid-call).
    private func beginCallRecording(on rtp: RTPSession) {
        guard callRecorder == nil else { return }
        let codec = rtp.codec
        let stamp = Self.recordingStampFormatter.string(from: Date())
        let url = recordingsDirectory
            .appendingPathComponent("call-\(stamp).wav")
        do {
            let rec = try CallRecorder(url: url, sampleRate: codec.inputSampleRate)
            callRecorder = rec
            callRecordingURL = url
            // Hold the recorder directly rather than reaching back through
            // `self.callRecorder`: this fires on the RTP send task every
            // ptime, and bouncing each frame to the MainActor just to read
            // a property would be pure overhead. CallRecorder is Sendable
            // and does its own locking.
            rtp.onSentPCM = { [weak rec] pcm in rec?.appendNear(pcm) }
            appendLog(.init(direction: .sent, kind: .info,
                summary: "Recording to \(url.lastPathComponent) "
                       + "(stereo, \(Int(codec.inputSampleRate)) Hz — "
                       + "left = us, right = peer)"))
        } catch {
            callRecordingArmed = false
            appendLog(.init(direction: .sent, kind: .error,
                summary: "Could not start recording: \(error.localizedDescription)"))
        }
    }

    /// Stop and finalise, whether the user asked or the call ended.
    func stopCallRecording() {
        callRecordingArmed = false
        currentRTPSession?.onSentPCM = nil
        guard let rec = callRecorder else { callRecordingURL = nil; return }
        callRecorder = nil
        let startedAt = rec.startedAt
        if let done = rec.finish() {
            lastFinishedRecording = (done.url, startedAt)
            appendLog(.init(direction: .sent, kind: .info,
                summary: String(format: "Recording saved: %@ (%.1f s)",
                                done.url.lastPathComponent, done.seconds),
                detail: "Stereo WAV — left channel is this client, right "
                      + "channel is the peer.\n\n\(done.url.path)",
                recordingURL: done.url))
            callRecordingURL = done.url
        } else {
            callRecordingURL = nil
        }
    }

    /// Show the finished recording in Finder.
    func revealCallRecording() {
        guard let url = callRecordingURL else { return }
        revealInFinder(url)
    }

    /// Select a file in Finder, or fall back to opening the containing
    /// folder if it has since been moved or deleted.
    func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private static let recordingStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private func detachAudio() {
        // Close the WAV first: the chart snapshot built below records a
        // reference to it, and that reference should only ever point at a
        // complete, playable file.
        stopCallRecording()
        if let metrics = callMetrics {
            appendLog(.init(direction: .sent, kind: .info,
                            summary: metrics.summaryLine,
                            detail: metrics.summaryDetail))
            // Stash a chart-only snapshot and drop a clickable "View In
            // Call Chart" entry into the wire log so users can revisit
            // the full delta + jitter timelines after the call ends.
            if !metrics.allSamples.isEmpty {
                let snapshot = CallChartSnapshot(
                    id: UUID(),
                    samples: metrics.allSamples,
                    nominalDeltaMs: metrics.nominalDeltaMs,
                    inviteAt: metrics.inviteAt,
                    answeredAt: metrics.answeredAt,
                    firstAudioAt: metrics.firstAudioAt,
                    endedAt: Date(),
                    recordingURL: lastFinishedRecording?.url,
                    recordingStartedAt: lastFinishedRecording?.startedAt
                )
                storeCallChart(snapshot)
                appendLog(.init(
                    direction: .sent, kind: .info,
                    summary: "View In Call Chart "
                           + "(\(metrics.allSamples.count) samples, "
                           + "\(formatChartDuration(metrics.allSamples)))",
                    detail: "Open the post-call delta + jitter charts "
                          + "in a separate window with hover values "
                          + "and drag-to-zoom.",
                    callChartID: snapshot.id
                ))
            }
        }
        callMicBuffer.clear()
        callPromptBuffer.clear()
        audioEngine.stopCallMode()
        rtpStatsTask?.cancel()
        rtpStatsTask = nil
        if let jb = jitterBuffer {
            let s = jb.snapshot()
            jb.stop()
            appendLog(.init(direction: .received, kind: .info,
                summary: String(format:
                    "Jitter buffer: produced=%llu plc=%llu droppedLate=%llu " +
                    "droppedOverflow=%llu prerolls=%llu finalTarget=%dms jitter=%.1fms",
                    s.produced, s.plcFrames, s.droppedLate, s.droppedOverflow,
                    s.prerolls, s.targetMs, s.jitterMs)))
        }
        jitterBuffer = nil
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
        applySuppressSendForCurrentMuteState()
        let muted = audioEngine.micMuted
        let extra = (muted && !currentSendSilenceWhileMuted) ? " (RTP send halted)" : ""
        appendLog(.init(
            direction: .sent, kind: .info,
            summary: muted ? "Mic muted\(extra)" : "Mic unmuted"
        ))
    }

    /// Mirror the dialer form's current state — saved or not — into
    /// AppState. Called on every edit, so inbound calls and scenarios see
    /// what the user is actually looking at.
    ///
    /// This replaced a pair of per-setting push methods that each had to
    /// be wired up by hand at the relevant toggle; every setting added
    /// after them was quietly stale until saved.
    func syncDraftProfile(_ profile: DialerProfile) {
        draftProfile = profile
        // `sendSilenceWhileMuted` is the one setting that also means
        // something *mid*-call — flipping it is how you exercise a peer's
        // media-timeout handling — so it applies to the live session at
        // once rather than waiting for the next call. Everything else is
        // read when the next call sets up its media.
        if currentSendSilenceWhileMuted != profile.sendSilenceWhileMuted {
            currentSendSilenceWhileMuted = profile.sendSilenceWhileMuted
            applySuppressSendForCurrentMuteState()
        }
    }

    /// The saved profile for `id`, overlaid with the dialer's unsaved
    /// edits when the form is showing that same profile. Use this
    /// anywhere a call is configured from a stored profile.
    func profileWithLiveEdits(id: UUID?) -> DialerProfile? {
        if let draft = draftProfile, draft.id == id { return draft }
        return profile(id: id)
    }

    /// Push the combined "muted + don't send silence while muted" state
    /// into the RTPSession so the send loop either keeps emitting comfort
    /// silence (default) or hard-stops RTP transmission entirely (test
    /// mode for peer media-timeout behaviour).
    private func applySuppressSendForCurrentMuteState() {
        let shouldSuppress = audioEngine.micMuted && !currentSendSilenceWhileMuted
        guard let rtp = currentRTPSession else {
            appendLog(.init(direction: .sent, kind: .info,
                summary: "RTP suppress: no active session "
                       + "(muted=\(audioEngine.micMuted), "
                       + "sendSilence=\(currentSendSilenceWhileMuted))"))
            return
        }
        let was = rtp.suppressSend
        rtp.suppressSend = shouldSuppress
        appendLog(.init(direction: .sent, kind: .info,
            summary: "RTP suppress \(was ? "on" : "off") → \(shouldSuppress ? "on" : "off") "
                   + "(muted=\(audioEngine.micMuted), "
                   + "sendSilence=\(currentSendSilenceWhileMuted))"))
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

    /// Run the scenario. If it has a profile, each iteration places that
    /// call first and runs the steps after; otherwise it runs once against
    /// the active call. Every iteration is scored pass/fail into
    /// `scenarioRun`.
    func runScenario(_ scenario: Scenario, authPassword: String = "") {
        guard runningScenarioID == nil else { return }
        let profile = scenario.profileID.flatMap { profileWithLiveEdits(id: $0) }
        if scenario.repeatCount > 1 {
            guard profile != nil else {
                appendLog(.init(direction: .sent, kind: .error,
                    summary: "Scenario “\(scenario.name)” repeats, so it needs a profile to dial"))
                return
            }
            guard !callInProgress else {
                appendLog(.init(direction: .sent, kind: .error,
                    summary: "Hang up the current call before starting a repeated scenario"))
                return
            }
        }

        runningScenarioID = scenario.id
        currentScenarioStep = nil
        currentScenarioIteration = nil
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "Running scenario: \(scenario.name)"))

        let iterations = profile == nil ? 1 : max(1, scenario.repeatCount)
        scenarioRun = ScenarioRunReport(scenarioID: scenario.id,
                                        scenarioName: scenario.name,
                                        profileName: profile?.name ?? "(active call)",
                                        startedAt: Date(),
                                        plannedIterations: iterations)
        scenarioRunReportURL = newScenarioReportURL(for: scenario)
        setScenarioIgnoresMic(scenario.ignoreMicrophone)

        scenarioTask = Task { [scenario] in
            for i in 1...iterations {
                if Task.isCancelled { break }
                self.currentScenarioIteration = i
                await self.runScenarioIteration(scenario, iteration: i,
                                                profile: profile,
                                                authPassword: authPassword,
                                                isLooping: iterations > 1)
                if i < iterations && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:
                        UInt64(max(0, scenario.pauseBetweenRuns) * 1_000_000_000))
                }
            }
            self.finishScenarioRun(cancelled: Task.isCancelled)
        }
    }

    func cancelScenario() {
        scenarioTask?.cancel()
        scenarioTask = nil
        // A repeated run owns its calls, so don't leave one dangling.
        if let run = scenarioRun, run.plannedIterations > 1, run.endedAt == nil,
           callInProgress {
            hangup()
            stopCallRecording()
        }
        finishScenarioRun(cancelled: true)
    }

    private func finishScenarioRun(cancelled: Bool) {
        guard runningScenarioID != nil else { return }
        runningScenarioID = nil
        currentScenarioStep = nil
        currentScenarioIteration = nil
        setScenarioIgnoresMic(false)
        if var run = scenarioRun {
            run.endedAt = Date()
            run.cancelled = cancelled
            scenarioRun = run
            writeScenarioReport()
            appendLog(.init(direction: .sent,
                            kind: run.failed > 0 ? .error : .info,
                            summary: "Scenario finished — \(run.summaryLine)"
                                   + (cancelled ? " (cancelled)" : ""),
                            detail: run.textReport))
        }
    }

    private func setScenarioIgnoresMic(_ ignore: Bool) {
        scenarioIgnoresMic = ignore
        currentRTPSession?.ignoreMic = ignore
    }

    /// Per-iteration state the steps read and fill in.
    private struct ScenarioIterationContext {
        let scenario: Scenario
        let placedCall: Bool
        /// Far-end speech has been heard at least once on this call.
        var heardFarEnd = false
        /// When our most recent prompt finished sending.
        var promptEndedAt: Date?
        var firstSpeechMs: Int?
        var responseLatencyMs: Int?
    }

    private func runScenarioIteration(_ scenario: Scenario, iteration: Int,
                                      profile: DialerProfile?, authPassword: String,
                                      isLooping: Bool) async {
        let startedAt = Date()
        var callID = currentCall?.callID ?? currentInboundCall?.callID ?? "(none)"
        var ctx = ScenarioIterationContext(scenario: scenario, placedCall: profile != nil)
        var failure: (step: Int, reason: String)?

        if let profile {
            if isLooping && scenario.recordingPolicy != .off && !callRecordingArmed {
                toggleCallRecording()
            }
            if let id = placeCall(config: profile.callConfig(authPassword: authPassword)) {
                callID = id
            } else {
                failure = (0, "Could not place call: previous call still in progress")
            }
        }

        if failure == nil {
            for (idx, step) in scenario.steps.enumerated() {
                if Task.isCancelled { break }
                currentScenarioStep = idx
                if let reason = await executeStep(step, context: &ctx) {
                    failure = (idx, reason)
                    break
                }
            }
        }
        // A cancelled iteration is neither a pass nor a fail; it just stops.
        if Task.isCancelled { return }

        let metrics = callMetrics
        let answerMs: Int? = {
            guard let a = metrics?.answeredAt, let i = metrics?.inviteAt else { return nil }
            return Int(a.timeIntervalSince(i) * 1000)
        }()
        let packets = farEndSpeech?.packetsThisCall ?? 0
        let final = lastFinalResponse

        var recordingPath: String?
        if isLooping {
            if callInProgress { hangup() }
            await waitForCallToEnd(timeout: 10)
            // Disarms if the call never connected; finalises otherwise.
            stopCallRecording()
            if scenario.recordingPolicy != .off,
               let rec = lastFinishedRecording, rec.startedAt >= startedAt {
                if failure == nil && scenario.recordingPolicy == .failuresOnly {
                    try? FileManager.default.removeItem(at: rec.url)
                } else {
                    recordingPath = rec.url.path
                }
            }
        }

        let result = ScenarioIterationResult(
            iteration: iteration,
            startedAt: startedAt,
            callID: callID,
            passed: failure == nil,
            failedStep: failure?.step,
            failedStepLabel: failure.map { scenario.steps.indices.contains($0.step)
                ? scenario.steps[$0.step].typeLabel : "Place call" },
            reason: failure?.reason,
            sipStatus: final?.status,
            correlationHeaders: final?.headers ?? [:],
            answerMs: answerMs,
            firstSpeechMs: ctx.firstSpeechMs,
            responseLatencyMs: ctx.responseLatencyMs,
            rtpPacketsReceived: packets,
            recordingPath: recordingPath)
        scenarioRun?.results.append(result)
        writeScenarioReport()

        if let failure {
            appendLog(.init(direction: .sent, kind: .error,
                summary: "Scenario call #\(iteration) FAILED at step \(failure.step + 1): "
                       + failure.reason,
                detail: "Call-ID: \(callID)"))
        } else {
            appendLog(.init(direction: .sent, kind: .info,
                summary: "Scenario call #\(iteration) passed (Call-ID \(callID))"))
        }
    }

    /// Wait for the call and its media to be fully torn down, so the next
    /// iteration can dial. Gives up early if the run is cancelled.
    private func waitForCallToEnd(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (callInProgress || currentRTPSession != nil) && Date() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Run one step. Returns nil on success, or why it failed.
    private func executeStep(_ step: ScenarioStep,
                             context ctx: inout ScenarioIterationContext) async -> String? {
        switch step {
        case .waitForAnswer(let timeout):
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Task.isCancelled { return nil }
                if callConnected { return nil }
                if ctx.placedCall && !callInProgress {
                    return "Call failed before answer — \(callStatus)"
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "waitForAnswer timed out after \(Int(timeout))s"))
            return "No answer within \(Int(timeout)) s — \(callStatus)"
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        case .playClip(let clipID):
            guard let clip = audioClips.first(where: { $0.id == clipID }) else {
                appendLog(.init(direction: .sent, kind: .error,
                                summary: "Clip not found in scenario"))
                return "Clip not found in the audio library"
            }
            guard let samples = clipSamplesForCurrentCall(clip) else {
                return "No active call to play “\(clip.name)” into"
            }
            if let err = await playPrompt(samples) { return err }
            ctx.promptEndedAt = Date()
            return nil
        case .speak(let text):
            guard let rtp = currentRTPSession else { return "No active call to speak into" }
            let rate = rtp.codec.inputSampleRate
            let key = "\(Int(rate))|\(text)"
            var samples = synthesizedPrompts[key]
            if samples == nil {
                samples = await PromptAudio.synthesize(text, sampleRate: rate)
                synthesizedPrompts[key] = samples
            }
            guard let samples, !samples.isEmpty else {
                return "Speech synthesis failed for “\(text)”"
            }
            if let err = await playPrompt(samples) { return err }
            appendLog(.init(direction: .sent, kind: .info, summary: "Spoke: “\(text)”"))
            ctx.promptEndedAt = Date()
            return nil
        case .waitForSpeech(let timeout):
            return await waitForFarEndSpeech(timeout: timeout, context: &ctx)
        case .sendDTMF(let digits):
            guard let rtp = currentRTPSession else {
                appendLog(.init(direction: .sent, kind: .error,
                                summary: "Cannot send DTMF: no active call"))
                return "No active call to send DTMF on"
            }
            await rtp.sendDTMFDigits(digits)
            appendLog(.init(direction: .sent, kind: .info,
                            summary: "DTMF: \(digits)"))
            return nil
        case .hangup:
            hangup()
            return nil
        }
    }

    /// Send a prompt and wait until its last frame has gone out.
    private func playPrompt(_ samples: [Int16]) async -> String? {
        guard let rtp = currentRTPSession else { return "No active call" }
        callPromptBuffer.write(samples)
        let seconds = Double(samples.count) / rtp.codec.inputSampleRate
        let deadline = Date().addingTimeInterval(seconds + 5)
        while callPromptBuffer.availableSamples > 0 {
            if Task.isCancelled { return nil }
            if currentRTPSession !== rtp { return "Call ended while our prompt was playing" }
            if Date() > deadline { return "Prompt did not finish sending (RTP send stalled?)" }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // The final frame has been taken, not necessarily sent; give it one ptime.
        try? await Task.sleep(nanoseconds: UInt64(rtp.ptime) * 1_000_000)
        return nil
    }

    /// Speech must last this long in total before it counts, so a click
    /// or a burst of noise doesn't pass for the far end talking.
    private static let minSpeechMs: Double = 300
    /// Longest we'll wait for the far end to stop talking once it starts.
    private static let maxTurnSeconds: TimeInterval = 30

    private func waitForFarEndSpeech(timeout: TimeInterval,
                                     context ctx: inout ScenarioIterationContext) async -> String? {
        guard currentRTPSession != nil, let monitor = farEndSpeech else {
            return "No active call to listen on"
        }
        let threshold = ctx.scenario.speechThresholdDbfs
        monitor.mark(thresholdDbfs: threshold)
        let start = Date()

        // 1. Onset.
        while monitor.snapshot().speechMs < Self.minSpeechMs {
            if Task.isCancelled { return nil }
            if !callInProgress { return "Call ended while waiting for far-end speech" }
            if Date().timeIntervalSince(start) >= timeout {
                return diagnoseNoSpeech(monitor, timeout: timeout,
                                        threshold: threshold, context: ctx)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let first = monitor.snapshot().firstSpeechAt {
            if !ctx.heardFarEnd, let answered = callMetrics?.answeredAt {
                ctx.firstSpeechMs = Int(first.timeIntervalSince(answered) * 1000)
            }
            if let prompt = ctx.promptEndedAt {
                ctx.responseLatencyMs = Int(first.timeIntervalSince(prompt) * 1000)
            }
        }
        ctx.heardFarEnd = true

        // 2. Let them finish, so a following prompt doesn't talk over them.
        let turnDeadline = Date().addingTimeInterval(Self.maxTurnSeconds)
        while Date() < turnDeadline {
            if Task.isCancelled || !callInProgress { break }
            if let last = monitor.snapshot().lastSpeechAt,
               Date().timeIntervalSince(last) >= ctx.scenario.endOfTurnSilence {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Explain a silent wait in terms of which media direction looks broken.
    private func diagnoseNoSpeech(_ monitor: SpeechActivityMonitor, timeout: TimeInterval,
                                  threshold: Double,
                                  context ctx: ScenarioIterationContext) -> String {
        let s = monitor.snapshot()
        let secs = Int(timeout)
        let peak = s.peakDbfs.isFinite ? String(format: "%.0f dBFS", s.peakDbfs) : "digital silence"
        if monitor.packetsThisCall == 0 {
            return "No RTP received from the far end at all (inbound media never arrived)"
        }
        if s.packets == 0 {
            return "Inbound RTP stopped — none in the last \(secs) s "
                 + "(\(monitor.packetsThisCall) packets earlier in the call)"
        }
        if ctx.heardFarEnd && ctx.promptEndedAt != nil {
            return "Far end was heard earlier but didn't reply to our prompt within \(secs) s "
                 + "(inbound RTP flowing, peak \(peak)) — our audio may not be reaching it"
        }
        return "Inbound RTP flowing (\(s.packets) packets) but no speech in \(secs) s: "
             + "peak \(peak), threshold \(Int(threshold)) dBFS"
             + (s.speechMs > 0 ? ", only \(Int(s.speechMs)) ms above it" : "")
    }

    // MARK: Scenario reports

    private var scenarioRunsDirectory: URL {
        let dir = appSupportDir.appendingPathComponent("ScenarioRuns", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func newScenarioReportURL(for scenario: Scenario) -> URL {
        let stamp = Self.recordingStampFormatter.string(from: Date())
        let safe = scenario.name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "_")
        return scenarioRunsDirectory.appendingPathComponent("\(stamp) \(safe).txt")
    }

    /// Rewritten after every call, so a crash or quit mid-run still
    /// leaves everything up to that point on disk.
    private func writeScenarioReport() {
        guard let run = scenarioRun, let url = scenarioRunReportURL else { return }
        try? run.textReport.write(to: url, atomically: true, encoding: .utf8)
        try? run.csv.write(to: url.deletingPathExtension().appendingPathExtension("csv"),
                           atomically: true, encoding: .utf8)
    }

    func copyScenarioReport() {
        guard let run = scenarioRun else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.textReport, forType: .string)
    }

    func revealScenarioReport() {
        guard let url = scenarioRunReportURL else { return }
        revealInFinder(url)
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
        guard let samples = clipSamplesForCurrentCall(clip) else { return }
        callPromptBuffer.write(samples)
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "Queued clip “\(clip.name)” into call (\(samples.count) samples)"))
    }

    /// Load a clip resampled to the active call's codec rate. Library
    /// clips are 8 kHz; written in raw they'd play fast on any wideband
    /// codec.
    private func clipSamplesForCurrentCall(_ clip: AudioClip) -> [Int16]? {
        guard let rtp = currentRTPSession else {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Cannot play clip: no active call"))
            return nil
        }
        guard let loaded = try? WAVFile.read(url: clip.fileURL) else {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Cannot read clip “\(clip.name)”"))
            return nil
        }
        return PromptAudio.resample(loaded.samples,
                                    from: Double(loaded.sampleRate),
                                    to: rtp.codec.inputSampleRate)
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
