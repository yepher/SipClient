import Foundation

/// Energy-based detector for "is the far end talking?", fed with every
/// decoded inbound RTP frame. Scenarios use it to tell a call where the
/// agent was heard from one where media flowed but carried silence, or
/// never flowed at all — the distinction that matters when chasing
/// one-way audio.
///
/// Counters are relative to the last `mark`, so each scenario step asks
/// only about audio that arrived after it started.
final class SpeechActivityMonitor: @unchecked Sendable {
    struct Snapshot {
        /// RTP frames decoded since the mark, speech or not.
        var packets: Int
        /// Total duration of frames at or above the threshold.
        var speechMs: Double
        /// Loudest frame since the mark, in dBFS (-inf before any audio).
        var peakDbfs: Double
        var firstSpeechAt: Date?
        var lastSpeechAt: Date?
    }

    private let lock = NSLock()
    private var thresholdDbfs: Double = -40
    private var snap = Snapshot(packets: 0, speechMs: 0, peakDbfs: -.infinity)
    /// Lifetime count, so a step can tell "no RTP this call" from "no RTP
    /// since I started waiting".
    private var totalPackets = 0

    /// Reset the counters and set the level that counts as speech.
    func mark(thresholdDbfs: Double) {
        lock.lock(); defer { lock.unlock() }
        self.thresholdDbfs = thresholdDbfs
        snap = Snapshot(packets: 0, speechMs: 0, peakDbfs: -.infinity)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snap
    }

    var packetsThisCall: Int {
        lock.lock(); defer { lock.unlock() }
        return totalPackets
    }

    /// Called from the RTP receive task.
    func feed(_ samples: [Int16], sampleRate: Double, at time: Date) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        var sumSquares = 0.0
        for s in samples {
            let v = Double(s)
            sumSquares += v * v
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        let dbfs = rms > 0 ? 20 * log10(rms / 32768) : -.infinity
        let ms = Double(samples.count) / sampleRate * 1000

        lock.lock(); defer { lock.unlock() }
        totalPackets += 1
        snap.packets += 1
        snap.peakDbfs = max(snap.peakDbfs, dbfs)
        if dbfs >= thresholdDbfs {
            snap.speechMs += ms
            if snap.firstSpeechAt == nil { snap.firstSpeechAt = time }
            snap.lastSpeechAt = time
        }
    }
}
