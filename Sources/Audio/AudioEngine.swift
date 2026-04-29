import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Audio I/O for the SIP client.
///
/// Mic capture and recording share the engine's input node; only one tap
/// can be installed at a time. Playback through the speakers is independent.
@MainActor
final class AudioEngine: ObservableObject {
    enum Mode: Equatable {
        case idle
        case call
        case record
    }

    @Published private(set) var mode: Mode = .idle
    /// Smoothed 0–1 send level (mic). Sampled at 15 Hz from `levelMeter`.
    @Published private(set) var sendLevel: Double = 0
    /// Smoothed 0–1 receive level (decoded RTP).
    @Published private(set) var recvLevel: Double = 0
    /// True when the local mic is muted: captured samples are dropped
    /// (encoder sees silence on the wire, send VU goes flat).
    @Published private(set) var micMuted: Bool = false

    /// Lock-protected mute flag readable from the audio queue thread.
    /// `micMuted` (the @Published) is the MainActor-side view that drives UI.
    private let mutedFlag = ThreadsafeFlag()

    func setMicMuted(_ muted: Bool) {
        mutedFlag.value = muted
        micMuted = muted
    }

    func toggleMicMuted() { setMicMuted(!micMuted) }

    let levelMeter = LevelMeter()

    /// Diagnostic callback invoked when an audio event worth logging happens
    /// (engine started, first frame produced, etc.). AppState wires this
    /// into the wire log.
    var onDiagnostic: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Player → mainMixer connection format. Mutates per call so playback
    /// matches the negotiated codec's native rate (8 kHz for G.711,
    /// 16 kHz for G.722). Reconnect requires the engine to be stopped.
    private var playFormat: AVAudioFormat
    /// Mic capture is done via AVCaptureSession instead of AVAudioEngine's
    /// input node — the latter is unreliable on macOS (delivers a single
    /// buffer and stalls; VPIO fails to construct an aggregate device on
    /// some Macs). AVAudioEngine is now used only for playback.
    private let micCapture = MicCapture()

    private let recordBuffer = LockedSampleBuffer()
    private var levelTimer: AnyCancellable?
    private var heartbeatTimer: AnyCancellable?
    /// Held weakly enough for a same-call restart after a device change.
    private weak var lastCallMicBuffer: FrameBuffer?
    private var lastCallCodec: CodecKind = .pcmu

    /// User-selected device IDs (kAudioObjectUnknown = use system default).
    private var preferredInputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var preferredOutputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Counters published by the audio thread for diagnostics. Reset
    /// each time call mode starts.
    let micFrameCount = ThreadsafeCounter()
    let micPeakTracker = PeakTracker()

    init() {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 8000, channels: 1, interleaved: false)
        else {
            fatalError("Could not build playback AVAudioFormat")
        }
        self.playFormat = f
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    }

    // MARK: - Device selection

    /// Currently active input device ID (or system default if not set).
    var currentInputDeviceID: AudioDeviceID {
        if preferredInputDeviceID != kAudioObjectUnknown {
            return preferredInputDeviceID
        }
        return AudioDevices.systemDefault(input: true) ?? kAudioObjectUnknown
    }

    /// Currently active output device ID (or system default).
    var currentOutputDeviceID: AudioDeviceID {
        if preferredOutputDeviceID != kAudioObjectUnknown {
            return preferredOutputDeviceID
        }
        return AudioDevices.systemDefault(input: false) ?? kAudioObjectUnknown
    }

    /// Set the input device. Mic capture goes through AudioQueueServices,
    /// which takes the device's UID. We resolve the UID from the
    /// AudioDeviceID via AudioDevices and restart MicCapture if a call
    /// or recording is in progress.
    func setInputDevice(_ id: AudioDeviceID) {
        preferredInputDeviceID = id
        let uid = AudioDevices.list(input: true).first(where: { $0.id == id })?.uid
        micCapture.preferredDeviceUID = uid
        onDiagnostic?("Selected input device id=\(id) uid=\(uid ?? "<default>")")

        // If we're actively capturing, restart MicCapture with the new
        // route. The queue is rebuilt because kAudioQueueProperty_CurrentDevice
        // can only be set before AudioQueueStart.
        if mode == .call || mode == .record {
            micCapture.stop()
            do {
                try micCapture.start()
            } catch {
                onDiagnostic?("Restart after input device change failed: \(error.localizedDescription)")
                if mode == .call { stopCallMode() }
            }
        }
        objectWillChange.send()
    }

    func setOutputDevice(_ id: AudioDeviceID) {
        preferredOutputDeviceID = id
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        applyOutputDevice()
        if wasRunning {
            do { try engine.start(); player.play() }
            catch { onDiagnostic?("Restart failed: \(error.localizedDescription)") }
        }
        onDiagnostic?("Selected output device id=\(id)")
        objectWillChange.send()
    }

    /// Input device routing is handled by AVCaptureSession picking the
    /// system default. This is a placeholder for when we map AudioDeviceID
    /// to AVCaptureDevice.uniqueID. Currently no-op.
    private func applyInputDevice() { }

    private func applyOutputDevice() {
        guard preferredOutputDeviceID != kAudioObjectUnknown,
              let au = engine.outputNode.audioUnit else { return }
        var deviceID = preferredOutputDeviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            onDiagnostic?("Failed to set output device (OSStatus \(status))")
        }
    }

    static func requestMicAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private func ensureRunning() throws {
        if !engine.isRunning {
            applyOutputDevice()
            do {
                try engine.start()
                onDiagnostic?("AVAudioEngine started")
            } catch {
                onDiagnostic?("AVAudioEngine start failed: \(error.localizedDescription)")
                throw error
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Call mode

    func startCallMode(micBuffer: FrameBuffer, codec: CodecKind) throws {
        guard mode == .idle else { return }
        lastCallMicBuffer = micBuffer
        lastCallCodec = codec
        micFrameCount.reset()
        micPeakTracker.reset()
        let levels = levelMeter
        let counter = micFrameCount
        let peaks = micPeakTracker

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        onDiagnostic?("Mic auth status: \(auth.rawValue) (3 = authorized)")
        guard auth == .authorized else {
            throw NSError(domain: "AudioEngine", code: 100, userInfo: [
                NSLocalizedDescriptionKey:
                    "Microphone permission not granted. Open System Settings → Privacy & Security → Microphone and enable SIP Client."
            ])
        }

        // Reconfigure player for this call's codec rate (8 kHz for G.711,
        // 16 kHz for G.722). The player → mainMixer connection format must
        // match what enqueuePlayback will produce.
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(player)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: codec.inputSampleRate,
                                         channels: 1, interleaved: false)
        else {
            throw NSError(domain: "AudioEngine", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "Could not build playback format for \(codec.rtpmapName)"
            ])
        }
        playFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        onDiagnostic?("Codec \(codec.rtpmapName) — playback at \(Int(codec.inputSampleRate)) Hz")

        // Start playback engine so RTP receive can flow.
        try ensureRunning()

        // Mic capture rate must match the encoder's input rate.
        micCapture.sampleRate = codec.inputSampleRate
        let onDiag = onDiagnostic
        let muted = mutedFlag
        micCapture.onDiagnostic = { msg in onDiag?(msg) }
        micCapture.onSamples = { samples in
            counter.increment()
            if muted.value {
                // Drive both meters to zero and skip the mic buffer
                // write so the RTP send loop encodes silence.
                let zeros = [Int16](repeating: 0, count: samples.count)
                zeros.withUnsafeBufferPointer { levels.recordSend($0) }
                peaks.update(0)
                return
            }
            levels.recordSend(samples)
            var peak: Int32 = 0
            for s in samples {
                let v = Int32(s)
                let absV = v < 0 ? -v : v
                if absV > peak { peak = absV }
            }
            peaks.update(peak)
            micBuffer.write(Array(samples))
        }
        do {
            try micCapture.start()
        } catch {
            onDiagnostic?("MicCapture start failed: \(error.localizedDescription)")
            throw error
        }

        // Heartbeat: every 1.5 seconds while in call mode, log how many
        // mic frames have arrived and the recent peak. Tells us quickly
        // whether capture is firing and whether samples are non-zero.
        heartbeatTimer = Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let count = self.micFrameCount.snapshot()
                let peak = self.micPeakTracker.drain()
                self.onDiagnostic?("mic heartbeat: frames=\(count) recent peak=\(peak)")
            }

        mode = .call
        startLevelTimer()
    }

    func stopCallMode() {
        guard mode == .call else { return }
        micCapture.stop()
        micCapture.onSamples = nil
        mode = .idle
        levelMeter.reset()
        stopLevelTimer()
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        sendLevel = 0
        recvLevel = 0
    }

    // MARK: - Record mode

    func startRecordMode() throws {
        guard mode == .idle else { return }
        recordBuffer.clear()
        let buf = recordBuffer
        let levels = levelMeter

        let onDiag = onDiagnostic
        micCapture.onDiagnostic = { msg in onDiag?(msg) }
        micCapture.onSamples = { samples in
            levels.recordSend(samples)
            buf.append(samples)
        }
        try micCapture.start()
        mode = .record
        startLevelTimer()
    }

    func stopRecordMode() -> [Int16] {
        guard mode == .record else { return [] }
        micCapture.stop()
        micCapture.onSamples = nil
        mode = .idle
        stopLevelTimer()
        sendLevel = 0
        recvLevel = 0
        return recordBuffer.drain()
    }

    // MARK: - Playback

    func enqueuePlayback(samples: [Int16]) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: playFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buf.floatChannelData?[0] else { return }
        for i in 0..<samples.count {
            dst[i] = Float(samples[i]) / 32768.0
        }
        try? ensureRunning()
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    // MARK: - Internal: level timer

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        // 15 Hz is enough for a smooth meter and ~1/8 the load of 60 Hz.
        levelTimer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let snap = self.levelMeter.snapshot()
                self.sendLevel = LevelMeter.displayLevel(snap.send)
                self.recvLevel = LevelMeter.displayLevel(snap.recv)
            }
    }

    private func stopLevelTimer() {
        levelTimer?.cancel()
        levelTimer = nil
    }

}

final class ThreadsafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

final class ThreadsafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func reset() { lock.lock(); value = 0; lock.unlock() }
}

final class PeakTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int32 = 0
    func update(_ p: Int32) {
        lock.lock(); if p > peak { peak = p }; lock.unlock()
    }
    func drain() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let p = peak
        peak = 0
        return p
    }
    func reset() { lock.lock(); peak = 0; lock.unlock() }
}
