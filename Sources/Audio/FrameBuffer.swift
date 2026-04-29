import Foundation

/// Thread-safe FIFO of 16-bit mono 8 kHz PCM samples.
///
/// Producer (mic tap or clip iterator) calls `write`; consumer (RTP send
/// loop) calls `readFrame()` to pull 20 ms / 160-sample chunks. If no
/// frame is available the consumer should fall back to silence.
final class FrameBuffer: @unchecked Sendable {
    private var samples: [Int16] = []
    private let lock = NSLock()
    private let maxSamples: Int

    /// `maxSeconds` is the soft cap; older samples are dropped when exceeded.
    init(maxSeconds: Double = 1.0) {
        self.maxSamples = Int(maxSeconds * 8000)
    }

    func write(_ chunk: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Returns `nil` if fewer than 160 samples are buffered.
    func readFrame() -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        guard samples.count >= 160 else { return nil }
        let out = Array(samples.prefix(160))
        samples.removeFirst(160)
        return out
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    var availableSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }
}
