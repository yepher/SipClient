import Foundation

/// Records a live call to a two-channel WAV file:
///
///   * **left**  — the near end: exactly the PCM handed to the encoder, so
///     it includes injected audio clips and the comfort silence sent while
///     muted, not just what the microphone heard.
///   * **right** — the far end: the PCM handed to the speaker, i.e. what
///     you actually heard after jitter buffering and packet-loss fill.
///
/// Left is always *this* client and right is always the peer, whichever
/// side placed the call.
///
/// ## Keeping the two channels aligned
///
/// The two sides run on independent clocks. The RTP send loop ticks on its
/// own 20 ms timer; received audio lands whenever the network delivers it,
/// and either side can stop entirely for a while — mute, DTMF, packet
/// loss, a relay that batches. Appending each side to its own channel as
/// it arrives would let them slide apart over a long call, and the error
/// would accumulate.
///
/// So neither side drives the file. Both are pinned to wall-clock: each
/// flush computes how many frames *should* exist by now (elapsed ×
/// sample rate) and writes exactly that many, drawing from each side's
/// FIFO and padding with silence where a side has nothing to give. A side
/// that stalls gets silence; a side whose clock runs fast has its excess
/// dropped once the backlog exceeds `maxBacklog`. Neither can drift.
///
/// The residual error is bounded by the jitter between the two producers
/// (tens of milliseconds) and does not grow with call length.
final class CallRecorder: @unchecked Sendable {
    /// Where the recording is being written.
    let url: URL
    /// Sample rate, which is the negotiated codec's rate — 8 kHz for
    /// G.711, 16 kHz for G.722 and AMR-WB.
    let sampleRate: Double

    /// Wall-clock instant of the first frame. The call charts use this
    /// to line the waveform up with the jitter timeline.
    let startedAt: Date

    private let lock = NSLock()
    private let writer: WAVFile.StreamWriter
    /// Stereo frames (sample pairs) committed to the file so far.
    private var framesWritten = 0
    private var near: [Int16] = []
    private var far: [Int16] = []
    private var finished = false
    /// One second. Past this a side is producing faster than real time,
    /// so drop its oldest samples rather than grow without bound.
    private let maxBacklog: Int

    init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.writer = try WAVFile.StreamWriter(url: url,
                                               sampleRate: UInt32(sampleRate),
                                               channels: 2)
        self.startedAt = Date()
        self.maxBacklog = Int(sampleRate)
    }

    /// PCM we are about to send. Called from the RTP send task.
    func appendNear(_ samples: [Int16]) { append(samples, near: true) }

    /// PCM we are about to play. Called from the playback path.
    func appendFar(_ samples: [Int16]) { append(samples, near: false) }

    private func append(_ samples: [Int16], near isNear: Bool) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if isNear { near.append(contentsOf: samples) }
        else      { far.append(contentsOf: samples) }
        if near.count > maxBacklog { near.removeFirst(near.count - maxBacklog) }
        if far.count  > maxBacklog { far.removeFirst(far.count - maxBacklog) }
        let elapsed = Date().timeIntervalSince(startedAt)
        flushLocked(upTo: Int(elapsed * sampleRate))
    }

    /// Write frames up to `target`, interleaving both sides and padding
    /// with silence wherever a side is short. Caller holds `lock`.
    private func flushLocked(upTo target: Int) {
        guard target > framesWritten else { return }
        let count = target - framesWritten
        var interleaved = [Int16](repeating: 0, count: count * 2)
        let nearTake = min(count, near.count)
        let farTake  = min(count, far.count)
        for i in 0..<nearTake { interleaved[i * 2]     = near[i] }
        for i in 0..<farTake  { interleaved[i * 2 + 1] = far[i] }
        if nearTake > 0 { near.removeFirst(nearTake) }
        if farTake  > 0 { far.removeFirst(farTake) }
        try? writer.append(interleaved)
        framesWritten += count
    }

    /// Duration committed so far, for UI.
    var durationSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / sampleRate
    }

    /// Flush the tail, patch the WAV header and close. Safe to call more
    /// than once; later calls return nil.
    @discardableResult
    func finish() -> (url: URL, seconds: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        // Commit whatever is still buffered, but only as much as actually
        // arrived — don't pad out to wall-clock past the last real audio.
        let tail = max(near.count, far.count)
        if tail > 0 { flushLocked(upTo: framesWritten + tail) }
        finished = true
        try? writer.close()
        return (url, Double(framesWritten) / sampleRate)
    }
}
