import Foundation

/// A simple lock-protected sample buffer used by `AudioEngine.record` mode.
///
/// We need a Sendable, non-isolated container because the audio tap fires
/// on a CoreAudio thread but our owning `AudioEngine` is `@MainActor`.
final class LockedSampleBuffer: @unchecked Sendable {
    private var samples: [Int16] = []
    private let lock = NSLock()

    func append(_ chunk: UnsafeBufferPointer<Int16>) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
    }

    func drain() -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: false)
        return out
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }
}
