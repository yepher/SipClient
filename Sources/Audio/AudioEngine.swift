import AVFoundation
import Foundation

/// Audio I/O for the SIP client.
///
/// Modes are mutually exclusive — only one mic tap can be installed at a
/// time. Playback through the speakers is independent and can run any time.
@MainActor
final class AudioEngine: ObservableObject {
    enum Mode: Equatable {
        case idle
        case call
        case record
    }

    @Published private(set) var mode: Mode = .idle
    /// Smoothed 0–1 send level (mic). Sampled at ~30 Hz from `levelMeter`.
    @Published private(set) var sendLevel: Double = 0
    /// Smoothed 0–1 receive level (decoded RTP). Sampled at ~30 Hz.
    @Published private(set) var recvLevel: Double = 0

    let levelMeter = LevelMeter()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat: AVAudioFormat
    private var tapInstalled = false

    private let recordBuffer = LockedSampleBuffer()

    init() {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 8000, channels: 1, interleaved: false)
        else {
            fatalError("Could not build playback AVAudioFormat")
        }
        self.playFormat = f
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        // 30 Hz level poll. Captures `holder` rather than self to avoid actor
        // isolation issues — the @Published writes still happen on MainActor
        // because Task inherits the enclosing isolation.
        let holder = levelMeter
        Task { [weak self] in
            while let self {
                let snap = holder.snapshot()
                self.sendLevel = LevelMeter.displayLevel(snap.send)
                self.recvLevel = LevelMeter.displayLevel(snap.recv)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
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
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Call mode

    func startCallMode(micBuffer: FrameBuffer) throws {
        guard mode == .idle else { return }
        let levels = levelMeter
        try installMicTap { samples in
            levels.recordSend(samples)
            micBuffer.write(Array(samples))
        }
        try ensureRunning()
        mode = .call
    }

    func stopCallMode() {
        guard mode == .call else { return }
        removeMicTap()
        mode = .idle
        levelMeter.reset()
    }

    // MARK: - Record mode

    func startRecordMode() throws {
        guard mode == .idle else { return }
        recordBuffer.clear()
        let buf = recordBuffer
        try installMicTap { samples in
            buf.append(samples)
        }
        try ensureRunning()
        mode = .record
    }

    func stopRecordMode() -> [Int16] {
        guard mode == .record else { return [] }
        removeMicTap()
        mode = .idle
        return recordBuffer.drain()
    }

    // MARK: - Playback

    /// Schedule 8 kHz mono Int16 PCM samples for playback through the speakers.
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

    /// Update the receive level from decoded RTP samples. Called by AppState
    /// from the RTP onPlaybackPCM hook before forwarding to enqueuePlayback.
    func recordRecvLevel(_ samples: [Int16]) {
        levelMeter.recordRecv(samples)
    }

    // MARK: - Internal: mic tap

    /// Install a tap on the mic that delivers 8 kHz mono Int16 chunks to `handler`.
    /// `handler` runs on a CoreAudio thread — keep it short and lock-light.
    private func installMicTap(_ handler: @escaping @Sendable (UnsafeBufferPointer<Int16>) -> Void) throws {
        precondition(!tapInstalled)
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Non-interleaved is required for `int16ChannelData` to return a
        // non-nil pointer. (For mono the data layout is the same either
        // way; the flag just controls which accessor populates.)
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let outFrames = AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * 8000.0 / inputFormat.sampleRate)
            ) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames)
            else { return }

            var fed = false
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError) { _, outStatus in
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

            // Prefer int16ChannelData; fall back to the raw audioBufferList
            // (works for either interleaved or planar formats).
            if let ptr = outBuf.int16ChannelData?[0] {
                handler(UnsafeBufferPointer(start: ptr, count: n))
                return
            }
            let abl = outBuf.audioBufferList
            let buf0 = abl.pointee.mBuffers
            guard let raw = buf0.mData else { return }
            let p = raw.assumingMemoryBound(to: Int16.self)
            handler(UnsafeBufferPointer(start: p, count: n))
        }
        tapInstalled = true
    }

    private func removeMicTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }
}
