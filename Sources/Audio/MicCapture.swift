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
    /// mono Int16 samples at `sampleRate`. The pointer's lifetime ends
    /// when the closure returns.
    var onSamples: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)?

    var onDiagnostic: (@Sendable (String) -> Void)?

    /// CoreAudio device UID to capture from. `nil` uses the system
    /// default input. Changes take effect on the next `start()`.
    var preferredDeviceUID: String?

    /// Sample rate to capture at. Defaults to 8 kHz (G.711). Set to
    /// 16000 for G.722, 48000 for Opus. AudioQueue handles resampling
    /// from the device's native rate internally. Takes effect on next
    /// `start()`.
    var sampleRate: Double = 8000

    private static let bufferCount = 3

    private var queue: AudioQueueRef?
    private var allocatedBuffers: [AudioQueueBufferRef] = []
    private var firstFrameLogged = false

    override init() {
        super.init()
    }

    var isRunning: Bool { queue != nil }

    func start() throws {
        guard queue == nil else { return }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

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

        // Route to a specific device, if one was chosen. AudioQueue takes
        // the device's UID as a CFString. Must be set after creation and
        // before AudioQueueStart.
        if let uid = preferredDeviceUID {
            var cfUID = uid as CFString
            let setStatus = withUnsafeMutablePointer(to: &cfUID) { ptr -> OSStatus in
                AudioQueueSetProperty(
                    q,
                    kAudioQueueProperty_CurrentDevice,
                    ptr,
                    UInt32(MemoryLayout<CFString>.size)
                )
            }
            if setStatus != noErr {
                onDiagnostic?("MicCapture failed to route to UID \(uid) (OSStatus \(setStatus)); using system default")
            } else {
                onDiagnostic?("MicCapture routed to UID \(uid)")
            }
        }

        let bytesPerFrame = asbd.mBytesPerFrame
        // 100 ms of buffer at the chosen rate (e.g. 800 frames at 8 kHz,
        // 1600 at 16 kHz, 4800 at 48 kHz).
        let captureBufferFrames = UInt32(sampleRate / 10)
        let bufferByteSize = captureBufferFrames * bytesPerFrame
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
        onDiagnostic?("MicCapture started: \(Int(sampleRate)) Hz mono Int16, "
                      + "\(Self.bufferCount)x\(captureBufferFrames)-frame buffers")
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

        let frameCount = byteCount / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return }

        let samples = UnsafeBufferPointer<Int16>(
            start: raw.assumingMemoryBound(to: Int16.self),
            count: frameCount
        )

        if !firstFrameLogged {
            firstFrameLogged = true
            onDiagnostic?("MicCapture first frame: \(frameCount) samples at \(Int(sampleRate)) Hz")
        }

        onSamples?(samples)
    }
}

/// C callback bridge — AudioQueue calls this on its internal thread.
private let inputCallback: AudioQueueInputCallback = {
    (userData, _, buffer, _, _, _) in
    guard let userData else { return }
    let mic = Unmanaged<MicCapture>.fromOpaque(userData).takeUnretainedValue()
    mic.handleBuffer(buffer)
}
