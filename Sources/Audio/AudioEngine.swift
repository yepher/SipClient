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

    /// Mic capture and speaker playback both use AudioQueueServices so
    /// `kAudioQueueProperty_CurrentDevice` can route them to a specific
    /// device (`MicCapture` for input, `SpeakerPlayback` for output).
    /// AVAudioEngine isn't used at all — its `outputNode.audioUnit`
    /// doesn't reliably accept a `CurrentDevice` property change at
    /// runtime, which broke device routing for AirPods etc.
    private let micCapture = MicCapture()
    private let speaker = SpeakerPlayback()

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

    init() {}

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

    /// Set the output device. Speaker playback goes through AudioQueueServices,
    /// which takes the device's UID (`kAudioQueueProperty_CurrentDevice`).
    /// We resolve the UID from the AudioDeviceID via AudioDevices and
    /// restart the playback queue if it's running so the new route takes
    /// effect immediately.
    func setOutputDevice(_ id: AudioDeviceID) {
        preferredOutputDeviceID = id
        let uid = AudioDevices.list(input: false).first(where: { $0.id == id })?.uid
        speaker.preferredDeviceUID = uid
        onDiagnostic?("Selected output device id=\(id) uid=\(uid ?? "<default>")")

        if speaker.isRunning {
            speaker.stop()
            do {
                try speaker.start()
            } catch {
                onDiagnostic?("Restart speaker after device change failed: \(error.localizedDescription)")
            }
        }
        objectWillChange.send()
    }

    static func requestMicAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
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

        // Configure the speaker playback queue for this call's codec
        // rate (8 kHz for G.711, 16 kHz for G.722) and start it.
        if speaker.isRunning { speaker.stop() }
        speaker.sampleRate = codec.inputSampleRate
        let onDiagS = onDiagnostic
        speaker.onDiagnostic = { msg in onDiagS?(msg) }
        do {
            try speaker.start()
        } catch {
            onDiagnostic?("SpeakerPlayback start failed: \(error.localizedDescription)")
            throw error
        }
        onDiagnostic?("Codec \(codec.rtpmapName) — playback at \(Int(codec.inputSampleRate)) Hz")

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
        speaker.stop()
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

    /// Enqueue Int16 PCM for the speaker. If called while no call is
    /// active (e.g. clip preview), boots the speaker queue at 8 kHz on
    /// the user's preferred output device.
    func enqueuePlayback(samples: [Int16]) {
        guard !samples.isEmpty else { return }
        if !speaker.isRunning {
            // Default rate for clip preview when no call is active.
            speaker.sampleRate = 8000
            let onDiag = onDiagnostic
            speaker.onDiagnostic = { msg in onDiag?(msg) }
            do {
                try speaker.start()
            } catch {
                onDiagnostic?("SpeakerPlayback start failed: \(error.localizedDescription)")
                return
            }
        }
        speaker.enqueue(samples: samples)
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
