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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat: AVAudioFormat
    private var tapInstalled = false

    /// Holds samples appended from the audio thread during record mode.
    /// Non-isolated so the audio-thread closure can mutate without
    /// crossing actor boundaries.
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
    }

    /// Request mic permission. macOS shows the TCC prompt on first call.
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
        try installMicTap { samples in
            // `samples` is a buffer pointer over the audio thread's lifetime —
            // copy out before returning.
            micBuffer.write(Array(samples))
        }
        try ensureRunning()
        mode = .call
    }

    func stopCallMode() {
        guard mode == .call else { return }
        removeMicTap()
        mode = .idle
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

    /// Stop recording and return the captured 8 kHz mono Int16 samples.
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

    // MARK: - Internal

    /// Install a tap on the mic that delivers 8 kHz mono Int16 chunks to `handler`.
    /// `handler` runs on a CoreAudio thread — keep it short and lock-light.
    private func installMicTap(_ handler: @escaping @Sendable (UnsafeBufferPointer<Int16>) -> Void) throws {
        precondition(!tapInstalled)
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 8000, channels: 1, interleaved: true)
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
            guard n > 0, let ptr = outBuf.int16ChannelData?[0] else { return }
            handler(UnsafeBufferPointer(start: ptr, count: n))
        }
        tapInstalled = true
    }

    private func removeMicTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }
}
