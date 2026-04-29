import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone samples via AudioQueueServices and delivers them
/// as 8 kHz mono Int16 frames.
///
/// AVAudioEngine's input tap and AVCaptureSession both proved unreliable
/// on macOS in our use case (single-buffer stalls; aggregate-device errors;
/// CMIO conflicts). AudioQueueServices is the long-standing, low-level
/// macOS API for raw audio capture and just works.
final class MicCapture: NSObject, @unchecked Sendable {
    /// Called from the AudioQueue's internal thread for each batch of
    /// 8 kHz mono Int16 samples. The pointer's lifetime ends when the
    /// closure returns.
    var onSamples: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)?

    var onDiagnostic: (@Sendable (String) -> Void)?

    private static let captureSampleRate: Double = 16000
    private static let captureBufferFrames: UInt32 = 1600 // 100 ms at 16 kHz
    private static let bufferCount = 3

    private var queue: AudioQueueRef?
    private var allocatedBuffers: [AudioQueueBufferRef] = []
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    private var firstFrameLogged = false

    override init() {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: 8000, channels: 1, interleaved: false)
        else { fatalError("Could not build 8 kHz mono Int16 format") }
        self.targetFormat = f
        super.init()
    }

    var isRunning: Bool { queue != nil }

    func start() throws {
        guard queue == nil else { return }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.captureSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        guard let src = AVAudioFormat(streamDescription: &asbd) else {
            throw NSError(domain: "MicCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not build source AVAudioFormat"
            ])
        }
        sourceFormat = src
        converter = AVAudioConverter(from: src, to: targetFormat)

        var newQueue: AudioQueueRef?
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewInput(
            &asbd,
            inputCallback,
            userData,
            nil,           // run loop (nil = internal queue)
            nil,           // run loop mode
            0,             // flags
            &newQueue
        )
        guard status == noErr, let q = newQueue else {
            throw NSError(domain: "MicCapture", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "AudioQueueNewInput failed (OSStatus \(status))"
            ])
        }

        let bytesPerFrame = asbd.mBytesPerFrame
        let bufferByteSize = Self.captureBufferFrames * bytesPerFrame
        for _ in 0..<Self.bufferCount {
            var buf: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(q, bufferByteSize, &buf)
            guard allocStatus == noErr, let buf else {
                AudioQueueDispose(q, true)
                throw NSError(domain: "MicCapture", code: Int(allocStatus), userInfo: [
                    NSLocalizedDescriptionKey: "AudioQueueAllocateBuffer failed (OSStatus \(allocStatus))"
                ])
            }
            allocatedBuffers.append(buf)
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }

        firstFrameLogged = false
        let startStatus = AudioQueueStart(q, nil)
        guard startStatus == noErr else {
            AudioQueueDispose(q, true)
            allocatedBuffers.removeAll()
            throw NSError(domain: "MicCapture", code: Int(startStatus), userInfo: [
                NSLocalizedDescriptionKey: "AudioQueueStart failed (OSStatus \(startStatus))"
            ])
        }

        queue = q
        onDiagnostic?("MicCapture started: \(Int(Self.captureSampleRate)) Hz mono Int16, "
                      + "\(Self.bufferCount)×\(Self.captureBufferFrames)-frame buffers")
    }

    func stop() {
        guard let q = queue else { return }
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
        queue = nil
        allocatedBuffers.removeAll()
    }

    /// Called from the audio queue thread.
    fileprivate func handleBuffer(_ buffer: AudioQueueBufferRef) {
        guard let queue = queue else { return }
        defer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0,
              let raw = buffer.pointee.mAudioData as UnsafeMutableRawPointer?
        else { return }

        let inFrameCount = byteCount / MemoryLayout<Int16>.size
        let inSamples = UnsafeBufferPointer<Int16>(
            start: raw.assumingMemoryBound(to: Int16.self),
            count: inFrameCount
        )

        // Downsample 16 kHz → 8 kHz by simple decimation (every 2nd sample).
        // This is fine for telephony-band audio — we only care about
        // 0–4 kHz so aliasing risk is minimal at this rate.
        let outFrameCount = inFrameCount / 2
        guard outFrameCount > 0 else { return }

        var out = [Int16](repeating: 0, count: outFrameCount)
        for i in 0..<outFrameCount {
            out[i] = inSamples[i * 2]
        }

        if !firstFrameLogged {
            firstFrameLogged = true
            onDiagnostic?("MicCapture first frame: \(outFrameCount) samples (8 kHz)")
        }

        out.withUnsafeBufferPointer { bp in
            onSamples?(bp)
        }
    }
}

/// C callback bridge — AudioQueue calls this on its internal thread.
private let inputCallback: AudioQueueInputCallback = {
    (userData, _, buffer, _, _, _) in
    guard let userData else { return }
    let mic = Unmanaged<MicCapture>.fromOpaque(userData).takeUnretainedValue()
    mic.handleBuffer(buffer)
}
