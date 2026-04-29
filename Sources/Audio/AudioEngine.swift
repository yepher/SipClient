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

    let levelMeter = LevelMeter()

    /// Diagnostic callback invoked when an audio event worth logging happens
    /// (engine started, first frame produced, etc.). AppState wires this
    /// into the wire log.
    var onDiagnostic: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat: AVAudioFormat
    private var tapInstalled = false
    private var firstFrameLogged = false
    private var firstNonSilentLogged = false

    private let recordBuffer = LockedSampleBuffer()
    private var levelTimer: AnyCancellable?
    private var heartbeatTimer: AnyCancellable?

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

    /// Set the input device. Audio units only accept a CurrentDevice
    /// change when stopped, so we cleanly stop the engine, swap, and
    /// resume if it was running.
    func setInputDevice(_ id: AudioDeviceID) {
        preferredInputDeviceID = id
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        applyInputDevice()
        if wasRunning {
            do { try engine.start(); player.play() }
            catch { onDiagnostic?("Restart failed: \(error.localizedDescription)") }
        }
        onDiagnostic?("Selected input device id=\(id)")
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

    /// Only push our preferred device into the engine if the user has
    /// explicitly chosen one. Calling AudioUnitSetProperty unconditionally
    /// (even with the system default) destabilises the HAL unit state.
    private func applyInputDevice() {
        guard preferredInputDeviceID != kAudioObjectUnknown,
              let au = engine.inputNode.audioUnit else { return }
        var deviceID = preferredInputDeviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            onDiagnostic?("Failed to set input device (OSStatus \(status))")
        }
    }

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
            // Apply user-selected devices before starting (audio units only
            // accept a device change while stopped).
            applyInputDevice()
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

    func startCallMode(micBuffer: FrameBuffer) throws {
        guard mode == .idle else { return }
        firstFrameLogged = false
        firstNonSilentLogged = false
        micFrameCount.reset()
        micPeakTracker.reset()
        let levels = levelMeter
        let counter = micFrameCount
        let peaks = micPeakTracker

        // Log the TCC permission status — useful sanity check.
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        onDiagnostic?("Mic auth status: \(auth.rawValue) (3 = authorized)")

        // Install the tap BEFORE the engine ever starts so input + output
        // are wired together from the first run.
        try installMicTap { samples in
            levels.recordSend(samples)
            counter.increment()
            var peak: Int32 = 0
            for s in samples {
                let v = Int32(s)
                let absV = v < 0 ? -v : v
                if absV > peak { peak = absV }
            }
            peaks.update(peak)
            micBuffer.write(Array(samples))
        }
        engine.prepare()
        try ensureRunning()

        // Heartbeat: every 1.5 seconds while in call mode, log how many
        // mic frames have arrived and the recent peak. Tells us very
        // quickly whether the tap is firing and whether samples are
        // non-zero.
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
        removeMicTap()
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
        try installMicTap { samples in
            levels.recordSend(samples)
            buf.append(samples)
        }
        try ensureRunning()
        mode = .record
        startLevelTimer()
    }

    func stopRecordMode() -> [Int16] {
        guard mode == .record else { return [] }
        removeMicTap()
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

    // MARK: - Internal: mic tap

    private func installMicTap(_ handler: @escaping @Sendable (UnsafeBufferPointer<Int16>) -> Void) throws {
        precondition(!tapInstalled)
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        onDiagnostic?("Mic input format: \(inputFormat)")

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 8000, channels: 1, interleaved: false)
        else {
            throw NSError(domain: "AudioEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build target audio format"])
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "AudioEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Cannot build AVAudioConverter (\(inputFormat) → \(target))"])
        }

        let firstFrameSignal = DiagnosticOnce()
        let firstAudibleSignal = DiagnosticOnce()
        let diag = onDiagnostic
        let inSampleRate = inputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            Self.processMicBuffer(
                buffer: buffer,
                converter: conv,
                target: target,
                inSampleRate: inSampleRate,
                firstFrame: firstFrameSignal,
                firstAudible: firstAudibleSignal,
                diag: diag,
                handler: handler
            )
        }
        tapInstalled = true
    }

    /// Static helper extracted so the closure passed to `installTap` is
    /// short enough for the Swift type checker to handle.
    private static func processMicBuffer(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat,
        inSampleRate: Double,
        firstFrame: DiagnosticOnce,
        firstAudible: DiagnosticOnce,
        diag: ((String) -> Void)?,
        handler: (UnsafeBufferPointer<Int16>) -> Void
    ) {
        let outFrames = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * 8000.0 / inSampleRate)
        ) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames)
        else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if !fed {
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { return }

        let n = Int(outBuf.frameLength)
        guard n > 0 else { return }

        let bp: UnsafeBufferPointer<Int16>
        if let p = outBuf.int16ChannelData?[0] {
            bp = UnsafeBufferPointer(start: UnsafePointer(p), count: n)
        } else if let raw = outBuf.audioBufferList.pointee.mBuffers.mData {
            let sp = raw.assumingMemoryBound(to: Int16.self)
            bp = UnsafeBufferPointer(start: sp, count: n)
        } else {
            return
        }

        firstFrame.fireOnce { diag?("First mic frame: \(n) samples") }

        var peak: Int32 = 0
        for s in bp {
            let v = Int32(s)
            let abs = v < 0 ? -v : v
            if abs > peak { peak = abs }
        }
        if peak > 300 {
            firstAudible.fireOnce {
                diag?("First audible mic frame: peak=\(peak)")
            }
        }
        handler(bp)
    }

    private func removeMicTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }
}

/// Tiny one-shot guard used to fire diagnostic logs once. Safe across
/// audio threads.
private final class DiagnosticOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fireOnce(_ block: () -> Void) {
        lock.lock()
        let go = !fired
        fired = true
        lock.unlock()
        if go { block() }
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
