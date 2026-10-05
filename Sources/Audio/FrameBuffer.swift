import Foundation

/// Thread-safe FIFO of 16-bit mono PCM samples.
///
/// Producer (mic capture or clip iterator) calls `write`; consumer (RTP
/// send loop) calls `readFrame(size:)` to pull a codec-sized chunk. If no
/// frame is available the consumer should fall back to silence.
final class FrameBuffer: @unchecked Sendable {
    private var samples: [Int16] = []
    private let lock = NSLock()
    private let maxSamples: Int

    /// `maxSeconds` is the soft cap. `sampleRate` sets the cap in samples
    /// — pass the codec's input sample rate so the cap is the same number
    /// of seconds regardless of codec.
    init(maxSeconds: Double = 1.0, sampleRate: Double = 8000) {
        self.maxSamples = Int(maxSeconds * sampleRate)
    }

    func write(_ chunk: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Returns `nil` if fewer than `size` samples are buffered.
    func readFrame(size: Int) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        guard samples.count >= size else { return nil }
        let out = Array(samples.prefix(size))
        samples.removeFirst(size)
        return out
    }

    /// Like `readFrame`, but hands back a partial final frame padded with
    /// silence instead of holding it back. Returns `nil` only when empty.
    /// For finite sources (prompts) whose tail would otherwise never send.
    func readFramePadded(size: Int) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        let n = min(size, samples.count)
        var out = Array(samples.prefix(n))
        samples.removeFirst(n)
        if n < size { out.append(contentsOf: [Int16](repeating: 0, count: size - n)) }
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
