import AudioToolbox
import Foundation

/// Plays back mono Int16 PCM samples via AudioQueueServices.
///
/// AVAudioEngine's `outputNode.audioUnit` doesn't reliably accept a
/// `kAudioOutputUnitProperty_CurrentDevice` change at runtime — the AU
/// is already initialized and the property is rejected. AudioQueue's
/// `kAudioQueueProperty_CurrentDevice` works cleanly when set before
/// `AudioQueueStart`. Symmetric with `MicCapture` for input.
final class SpeakerPlayback: NSObject, @unchecked Sendable {
    /// Sample rate of incoming PCM. Defaults to 8 kHz; AudioEngine sets
    /// to the codec's native rate when starting a call. Takes effect on
    /// next `start()`.
    var sampleRate: Double = 8000

    /// CoreAudio device UID to play into. `nil` uses the system default
    /// output. Takes effect on next `start()`.
    var preferredDeviceUID: String?

    var onDiagnostic: (@Sendable (String) -> Void)?

    private static let bufferCount = 4
    private static let bufferDurationMs = 20.0

    private var queue: AudioQueueRef?
    private var allocatedBuffers: [AudioQueueBufferRef] = []

    private let pendingLock = NSLock()
    private var pending: [Int16] = []
    private var maxPending: Int = 4000   // ~500 ms at 8 kHz; recomputed on start

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
        let status = AudioQueueNewOutput(
            &asbd,
            outputCallback,
            userData,
            nil,        // run loop
            nil,        // run loop mode
            0,          // flags
            &newQueue
        )
        guard status == noErr, let q = newQueue else {
            throw NSError(domain: "SpeakerPlayback", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "AudioQueueNewOutput failed (OSStatus \(status))"
            ])
        }

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
                onDiagnostic?("SpeakerPlayback failed to route to UID \(uid) (OSStatus \(setStatus))")
            } else {
                onDiagnostic?("SpeakerPlayback routed to UID \(uid)")
            }
        }

        let framesPerBuffer = UInt32(sampleRate * Self.bufferDurationMs / 1000.0)
        let bufferByteSize = framesPerBuffer * UInt32(MemoryLayout<Int16>.size)
        for _ in 0..<Self.bufferCount {
            var buf: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(q, bufferByteSize, &buf)
            guard allocStatus == noErr, let buf else {
                AudioQueueDispose(q, true)
                throw NSError(domain: "SpeakerPlayback", code: Int(allocStatus), userInfo: [
                    NSLocalizedDescriptionKey: "AudioQueueAllocateBuffer failed"
                ])
            }
            allocatedBuffers.append(buf)
            buf.pointee.mAudioDataByteSize = bufferByteSize
            memset(buf.pointee.mAudioData, 0, Int(bufferByteSize))
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }

        // Cap pending buffer at ~500 ms to keep latency bounded.
        maxPending = Int(sampleRate / 2)

        queue = q
        let startStatus = AudioQueueStart(q, nil)
        guard startStatus == noErr else {
            AudioQueueDispose(q, true)
            queue = nil
            allocatedBuffers.removeAll()
            throw NSError(domain: "SpeakerPlayback", code: Int(startStatus), userInfo: [
                NSLocalizedDescriptionKey: "AudioQueueStart failed (OSStatus \(startStatus))"
            ])
        }
        onDiagnostic?("SpeakerPlayback started: \(Int(sampleRate)) Hz mono Int16, "
                      + "\(Self.bufferCount)x\(framesPerBuffer)-frame buffers")
    }

    func stop() {
        guard let q = queue else { return }
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
        queue = nil
        allocatedBuffers.removeAll()
        pendingLock.lock()
        pending.removeAll(keepingCapacity: true)
        pendingLock.unlock()
    }

    /// Append samples to the pending playback FIFO.
    func enqueue(samples: [Int16]) {
        pendingLock.lock()
        pending.append(contentsOf: samples)
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }
        pendingLock.unlock()
    }

    /// Called from the AudioQueue thread when a buffer has finished
    /// playing. We refill it from `pending` (padding with silence if
    /// pending is short) and re-enqueue it.
    fileprivate func refillBuffer(_ buffer: AudioQueueBufferRef) {
        guard let queue = queue else { return }
        let frameCapacity = Int(buffer.pointee.mAudioDataBytesCapacity)
            / MemoryLayout<Int16>.size
        let dst = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)

        pendingLock.lock()
        let take = min(frameCapacity, pending.count)
        if take > 0 {
            _ = pending.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!,
                       take * MemoryLayout<Int16>.size)
            }
            pending.removeFirst(take)
        }
        pendingLock.unlock()

        if take < frameCapacity {
            memset(dst.advanced(by: take), 0,
                   (frameCapacity - take) * MemoryLayout<Int16>.size)
        }
        buffer.pointee.mAudioDataByteSize =
            UInt32(frameCapacity * MemoryLayout<Int16>.size)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

/// C callback bridge — AudioQueue calls this on its internal thread.
private let outputCallback: AudioQueueOutputCallback = {
    (userData, _, buffer) in
    guard let userData else { return }
    let speaker = Unmanaged<SpeakerPlayback>.fromOpaque(userData).takeUnretainedValue()
    speaker.refillBuffer(buffer)
}
