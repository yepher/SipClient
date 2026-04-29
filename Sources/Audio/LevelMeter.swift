import Foundation

/// Lock-protected, non-isolated holder for the most recent send/receive
/// audio levels. The audio tap (off the main thread) writes; a periodic
/// poll on the main actor reads and applies decay.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sendPeak: Double = 0
    private var recvPeak: Double = 0

    func recordSend(_ samples: UnsafeBufferPointer<Int16>) {
        let r = Self.rms(samples)
        lock.lock(); sendPeak = max(sendPeak, r); lock.unlock()
    }

    func recordRecv(_ samples: [Int16]) {
        let r = samples.withUnsafeBufferPointer { Self.rms($0) }
        lock.lock(); recvPeak = max(recvPeak, r); lock.unlock()
    }

    /// Returns the latest peaks and decays them so old values fade out.
    func snapshot() -> (send: Double, recv: Double) {
        lock.lock(); defer { lock.unlock() }
        let s = sendPeak, r = recvPeak
        sendPeak *= 0.55
        recvPeak *= 0.55
        return (s, r)
    }

    func reset() {
        lock.lock(); sendPeak = 0; recvPeak = 0; lock.unlock()
    }

    /// RMS of [-1, 1] scaled samples derived from Int16 PCM.
    private static func rms(_ s: UnsafeBufferPointer<Int16>) -> Double {
        guard !s.isEmpty else { return 0 }
        var sum: Double = 0
        for v in s {
            let f = Double(v) / 32768.0
            sum += f * f
        }
        return (sum / Double(s.count)).squareRoot()
    }

    /// Map a 0–1 RMS to a 0–1 display level using a -60..0 dB window.
    static func displayLevel(_ rms: Double) -> Double {
        let dB = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (dB + 60) / 60))
    }
}
