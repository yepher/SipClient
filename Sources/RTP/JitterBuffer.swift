import Foundation

/// Frame-keyed, sequence-ordered, adaptive jitter buffer for received RTP
/// audio. Sits between the RTP receive task (which feeds decoded PCM
/// frames as they arrive from the network) and the speaker enqueue path
/// (which wants frames at a steady 20 ms cadence).
///
/// Why we need it: SIP relays sometimes batch deliver — N packets bunched
/// every M·ptime. Without a buffer, the speaker FIFO sees the same
/// burstiness, producing audible underruns/overruns on the same period.
///
/// Strategy:
///   - Insert: store frame keyed by 32-bit extended seq, maintain
///     RFC 3550 §A.8 jitter estimate (in RTP-clock samples), update
///     adaptive target depth.
///   - Pull (every ptime): once preroll target reached, emit the next
///     extended-seq frame in order; if missing, emit silence (PLC) and
///     advance. If buffered depth grows past max, drop oldest frame(s).
///   - Late frames whose seq is below `nextExtSeq` are dropped.
///
/// Audio output cadence: a detached task ticks at `ptime` and forwards
/// each pulled frame via `onFrame`. Software timer drift is bounded by
/// the speaker's own ~500 ms FIFO cap, same as the no-jitter-buffer path.
final class JitterBuffer: @unchecked Sendable {

    struct Stats: Sendable {
        var inserted: UInt64 = 0
        var produced: UInt64 = 0          // frames emitted (real + PLC)
        var plcFrames: UInt64 = 0         // emitted silence for missing
        var droppedLate: UInt64 = 0       // arrived after we played past
        var droppedOverflow: UInt64 = 0   // trimmed when over max depth
        var prerolls: UInt64 = 0          // (re)arming events
        var jitterMs: Double = 0          // RFC 3550 jitter, ms
        var depthFrames: Int = 0          // current buffered frames
        var targetMs: Int = 0             // current adaptive target
        var armed: Bool = false
    }

    private let ptimeMs: Int
    private let samplesPerFrame: Int
    private let timestampPerFrame: UInt32
    private let rtpClockHz: Double                // 8000 for our codecs
    private let configuredTargetMs: Int
    private let minTargetMs: Int
    private let maxDepthMs: Int
    private let adaptive: Bool

    private let lock = NSLock()
    private var frames: [UInt32: [Int16]] = [:]  // ext-seq → samples
    private var firstSeq: UInt16?
    private var rocSeq: UInt32 = 0               // rollover counter
    private var maxExtSeq: UInt32 = 0            // highest ext-seq seen
    private var nextExtSeq: UInt32 = 0           // next ext-seq to emit
    private var armed: Bool = false

    // RFC 3550 §A.8 jitter math, all in RTP-clock samples.
    private var firstArrivedAt: Date?
    private var firstTimestamp: UInt32?
    private var prevTransit: Int64?
    private var jitterSamples: Double = 0
    private var currentTargetMs: Int

    private var stats = Stats()
    private var tickTask: Task<Void, Never>?

    /// Receives one ptime-sized frame at output cadence. Always full size;
    /// silence on PLC. Hopped off the tick task — implementer should
    /// dispatch to MainActor / audio queue as appropriate.
    var onFrame: (@Sendable ([Int16]) -> Void)?

    init(codec: CodecKind,
         ptimeMs: Int,
         targetMs: Int = 80,
         minTargetMs: Int = 40,
         maxDepthMs: Int = 200,
         adaptive: Bool = true) {
        self.ptimeMs = ptimeMs
        self.samplesPerFrame = Int(Double(ptimeMs) / 1000.0 * codec.inputSampleRate)
        self.timestampPerFrame = codec.timestampAdvance
        self.rtpClockHz = Double(codec.rtpClockRate)
        self.configuredTargetMs = max(ptimeMs, targetMs)
        self.minTargetMs = max(ptimeMs, minTargetMs)
        self.maxDepthMs = max(maxDepthMs, max(targetMs, ptimeMs) + ptimeMs)
        self.adaptive = adaptive
        self.currentTargetMs = self.configuredTargetMs
    }

    // MARK: - Insert

    /// Called from the RTP receive task with one decoded frame.
    func insert(samples: [Int16], seq: UInt16, timestamp: UInt32, arrivedAt: Date) {
        lock.lock()
        defer { lock.unlock() }

        stats.inserted &+= 1

        // Establish the extended-seq base on first packet.
        guard let first = firstSeq else {
            firstSeq = seq
            maxExtSeq = UInt32(seq)
            nextExtSeq = UInt32(seq)
            firstArrivedAt = arrivedAt
            firstTimestamp = timestamp
            frames[UInt32(seq)] = samples
            // Preroll begins now; armed flips once depth ≥ target.
            return
        }
        _ = first

        let prevLow = UInt16(maxExtSeq & 0xFFFF)
        let extSeq: UInt32
        if seq < prevLow && (UInt32(prevLow) - UInt32(seq)) > 32768 {
            extSeq = ((rocSeq &+ 1) << 16) | UInt32(seq)
            rocSeq &+= 1
        } else if seq > prevLow && (UInt32(seq) - UInt32(prevLow)) > 32768 && rocSeq > 0 {
            extSeq = ((rocSeq &- 1) << 16) | UInt32(seq)
        } else {
            extSeq = (rocSeq << 16) | UInt32(seq)
        }
        if extSeq > maxExtSeq { maxExtSeq = extSeq }

        // Drop too-late frames — we've already played past them.
        if armed && extSeq < nextExtSeq {
            stats.droppedLate &+= 1
            return
        }

        frames[extSeq] = samples

        // RFC 3550 §A.8 jitter: D = transit_n - transit_{n-1}, all in
        // RTP-clock samples. transit = arrival_samples - rtp_timestamp.
        if let firstAt = firstArrivedAt, let firstTS = firstTimestamp {
            let arrivalSamples = Int64((arrivedAt.timeIntervalSince(firstAt)) * rtpClockHz)
            let rtpSamples = Int64(Int32(bitPattern: timestamp &- firstTS))
            let transit = arrivalSamples - rtpSamples
            if let prev = prevTransit {
                let d = transit - prev
                let absD = Double(d < 0 ? -d : d)
                jitterSamples += (absD - jitterSamples) / 16.0
            }
            prevTransit = transit
        }

        // Adapt target depth: 4× jitter + 20 ms safety, clamped to
        // [configured, maxDepthMs - ptime]. Never below minTargetMs.
        if adaptive {
            let jitterMs = jitterSamples / rtpClockHz * 1000.0
            let proposed = Int(jitterMs * 4.0 + 20.0)
            let upperCap = max(minTargetMs, maxDepthMs - ptimeMs)
            let target = max(configuredTargetMs, max(minTargetMs, min(proposed, upperCap)))
            currentTargetMs = target
        } else {
            currentTargetMs = configuredTargetMs
        }

        // Trim oldest if we've blown past max depth.
        let maxFrames = max(1, maxDepthMs / ptimeMs)
        while frames.count > maxFrames {
            // Drop the smallest extSeq (oldest in stream order).
            if let oldest = frames.keys.min() {
                frames.removeValue(forKey: oldest)
                stats.droppedOverflow &+= 1
                if armed && oldest >= nextExtSeq {
                    // We dropped a frame we hadn't yet emitted; jump
                    // nextExtSeq forward so we don't try to play it.
                    nextExtSeq = oldest &+ 1
                }
            } else {
                break
            }
        }
    }

    // MARK: - Pull

    /// Pull the next ptime-sized frame. Returns nil while still pre-rolling
    /// (caller should emit nothing — the speaker FIFO already has its own
    /// prerolled silence buffers from AudioQueue start). Returns silence
    /// and advances on missing frame (PLC).
    func popFrame() -> [Int16]? {
        lock.lock()
        defer { lock.unlock() }

        if !armed {
            // Need at least targetMs of buffered frames before we start.
            let neededFrames = max(1, currentTargetMs / ptimeMs)
            if frames.count < neededFrames {
                return nil
            }
            // Arm: emit starting from the lowest buffered ext-seq.
            if let lowest = frames.keys.min() {
                nextExtSeq = lowest
            }
            armed = true
            stats.prerolls &+= 1
        }

        if let f = frames.removeValue(forKey: nextExtSeq) {
            nextExtSeq &+= 1
            stats.produced &+= 1
            return f
        }

        // Frame missing. Emit silence (PLC). If the buffer is empty AND
        // there's nothing newer than nextExtSeq buffered either, the
        // network has stalled — disarm and re-preroll instead of
        // emitting a stream of silence forever.
        if frames.isEmpty {
            armed = false
            // Don't bump nextExtSeq; whatever arrives next becomes the
            // new lowest and we re-arm from there.
            return nil
        }
        nextExtSeq &+= 1
        stats.produced &+= 1
        stats.plcFrames &+= 1
        return [Int16](repeating: 0, count: samplesPerFrame)
    }

    // MARK: - Lifecycle

    /// Start the output ticker. Each tick pulls one frame and (if non-nil)
    /// hands it to `onFrame`.
    func start() {
        guard tickTask == nil else { return }
        let interval: UInt64 = UInt64(ptimeMs) * 1_000_000
        tickTask = Task.detached(priority: .userInitiated) { [weak self] in
            var nextDeadline = DispatchTime.now().uptimeNanoseconds &+ interval
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    try? await Task.sleep(nanoseconds: nextDeadline - now)
                } else {
                    nextDeadline = now
                }
                nextDeadline &+= interval

                guard let self else { return }
                if let frame = self.popFrame() {
                    self.onFrame?(frame)
                }
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        lock.lock()
        frames.removeAll(keepingCapacity: false)
        armed = false
        prevTransit = nil
        jitterSamples = 0
        firstArrivedAt = nil
        firstTimestamp = nil
        firstSeq = nil
        rocSeq = 0
        nextExtSeq = 0
        maxExtSeq = 0
        lock.unlock()
    }

    // MARK: - Stats

    func snapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.depthFrames = frames.count
        s.targetMs = currentTargetMs
        s.armed = armed
        s.jitterMs = jitterSamples / rtpClockHz * 1000.0
        return s
    }
}
