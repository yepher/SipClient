import Foundation

/// Per-call timing milestones (all measured from INVITE-sent) plus a
/// sliding window of inbound RTP arrival statistics for the last 10
/// seconds (inter-arrival delta + smoothed jitter).
@MainActor
final class CallMetrics: ObservableObject {
    /// When the first INVITE went out. All durations are measured from
    /// here.
    @Published private(set) var inviteAt: Date?
    /// Receipt of the first 100 Trying.
    @Published private(set) var tryingAt: Date?
    /// Receipt of the first 180 Ringing.
    @Published private(set) var ringingAt: Date?
    /// Receipt of the 200 OK answering the INVITE.
    @Published private(set) var answeredAt: Date?
    /// First inbound RTP packet whose decoded payload exceeds the
    /// silence threshold (peak > 1000 in Int16 ≈ -30 dBFS).
    @Published private(set) var firstAudioAt: Date?
    /// Sliding window of inbound RTP arrival samples (last 10 s).
    @Published private(set) var samples: [ArrivalSample] = []

    /// Latest packet-loss snapshot from the inbound RTP stream.
    /// Updated periodically by the rtpStats polling task.
    @Published private(set) var packetsExpected: UInt64 = 0
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsLost: Int64 = 0

    /// Expected inter-arrival in ms — driven by the negotiated SDP
    /// `a=ptime` (RFC 4566). Defaults to 20 per RFC 3551 until the
    /// answer arrives. Used both for the chart's reference line and
    /// for the RFC 3550 jitter calculation.
    @Published private(set) var nominalDeltaMs: Double = 20

    private var lastArrival: Date?
    /// RFC 3550 §A.8 smoothed jitter, in ms.
    private var smoothedJitterMs: Double = 0

    /// Every observed inter-arrival delta and jitter value over the
    /// life of the call. The `samples` window prunes for the live
    /// chart; these arrays accumulate for end-of-call statistics.
    private var allDeltas: [Double] = []
    private var allJitters: [Double] = []
    /// Full-call (timestamped) sample stream — kept so the post-call
    /// "View In Call Chart" popout can render the entire duration with
    /// hover + zoom. Same shape as the live `samples` window.
    private(set) var allSamples: [ArrivalSample] = []

    private static let windowSeconds: TimeInterval = 10

    /// Update the nominal inter-arrival based on the negotiated
    /// SDP `a=ptime:` (in milliseconds).
    func setPtime(_ ptimeMs: Int) {
        guard ptimeMs > 0 else { return }
        nominalDeltaMs = Double(ptimeMs)
    }

    /// Push the current loss snapshot from RTPSession.
    func updateLossCounts(expected: UInt64, received: UInt64, lost: Int64) {
        packetsExpected = expected
        packetsReceived = received
        packetsLost = lost
    }

    /// Loss rate clamped at >= 0% (negative loss = duplicates from peer).
    var lossPercent: Double {
        guard packetsExpected > 0 else { return 0 }
        let lostNonNegative = max(Int64(0), packetsLost)
        return Double(lostNonNegative) / Double(packetsExpected) * 100
    }

    func recordInvite() {
        if inviteAt == nil { inviteAt = Date() }
    }

    func recordResponse(status: Int) {
        let now = Date()
        switch status {
        case 100:
            if tryingAt == nil { tryingAt = now }
        case 180:
            if ringingAt == nil { ringingAt = now }
        case 200:
            if answeredAt == nil { answeredAt = now }
        default:
            break
        }
    }

    /// Record one inbound RTP packet's arrival. `peak` is the maximum
    /// |sample| of the decoded PCM payload — used to detect when real
    /// audio (vs. comfort silence) starts after the call answers.
    func recordPacket(peak: Int32) {
        let now = Date()
        if let last = lastArrival {
            let deltaMs = now.timeIntervalSince(last) * 1000
            // RFC 3550 §A.8: J += (|D| - J) / 16, where D = delta - expected.
            let absDeviation = abs(deltaMs - nominalDeltaMs)
            smoothedJitterMs += (absDeviation - smoothedJitterMs) / 16
            let sample = ArrivalSample(
                at: now,
                deltaMs: deltaMs,
                jitterMs: smoothedJitterMs
            )
            samples.append(sample)
            // Trim samples older than the window.
            let cutoff = now.addingTimeInterval(-Self.windowSeconds)
            while let first = samples.first, first.at < cutoff {
                samples.removeFirst()
            }
            allDeltas.append(deltaMs)
            allJitters.append(smoothedJitterMs)
            allSamples.append(sample)
        }
        lastArrival = now

        if firstAudioAt == nil, answeredAt != nil, peak > 1000 {
            firstAudioAt = now
        }
    }

    /// Milliseconds from INVITE → the given milestone, or nil if either
    /// the milestone or invite hasn't fired yet.
    func msFromInvite(to milestone: Date?) -> Int? {
        guard let inviteAt, let milestone else { return nil }
        return Int(milestone.timeIntervalSince(inviteAt) * 1000)
    }

    /// One-line wire-log summary. Click the entry to see `summaryDetail`
    /// with the full distribution.
    var summaryLine: String {
        guard inviteAt != nil else { return "Call metrics: no INVITE sent" }
        var parts: [String] = []
        if let ms = msFromInvite(to: tryingAt) {     parts.append("100=\(ms)ms") }
        if let ms = msFromInvite(to: ringingAt) {    parts.append("180=\(ms)ms") }
        if let ms = msFromInvite(to: answeredAt) {   parts.append("200=\(ms)ms") }
        if let ms = msFromInvite(to: firstAudioAt) { parts.append("audio=\(ms)ms") }
        if let s = Self.stats(allDeltas) {
            parts.append(String(format: "Δ avg/p95/max=%.1f/%.1f/%.1fms",
                                s.avg, s.p95, s.max))
        }
        if let s = Self.stats(allJitters) {
            parts.append(String(format: "jit avg/p95/max=%.1f/%.1f/%.1fms",
                                s.avg, s.p95, s.max))
        }
        if packetsExpected > 0 {
            parts.append(String(
                format: "loss=%lld/%llu (%.2f%%)",
                packetsLost, packetsExpected, lossPercent
            ))
        }
        return "Call metrics — " + (parts.isEmpty ? "no responses" : parts.joined(separator: ", "))
    }

    /// Multi-line breakdown for the wire log entry's detail pane.
    var summaryDetail: String {
        var lines: [String] = ["Call metrics", ""]

        // Timing milestones.
        lines.append("Time to first (from INVITE):")
        let timing: [(String, Date?)] = [
            ("100 Trying  ", tryingAt),
            ("180 Ringing ", ringingAt),
            ("200 OK      ", answeredAt),
            ("First audio ", firstAudioAt),
        ]
        for (label, t) in timing {
            if let ms = msFromInvite(to: t) {
                lines.append(String(format: "  %@ %5d ms", label, ms))
            } else {
                lines.append("  \(label)    —")
            }
        }
        lines.append("")
        lines.append("Negotiated a=ptime: \(Int(nominalDeltaMs)) ms")
        lines.append("")

        if packetsExpected > 0 {
            lines.append("Packet loss:")
            lines.append("  expected:  \(packetsExpected)")
            lines.append("  received:  \(packetsReceived)")
            lines.append(String(format: "  lost:      %lld (%.2f%%)",
                                packetsLost, lossPercent))
            lines.append("")
        }

        if let s = Self.stats(allDeltas) {
            lines.append("Δ inter-arrival (n=\(s.count)):")
            lines.append(contentsOf: Self.formatStatsBlock(s, unit: "ms"))
            lines.append("")
        }
        if let s = Self.stats(allJitters) {
            lines.append("Jitter (n=\(s.count)):")
            lines.append(contentsOf: Self.formatStatsBlock(s, unit: "ms"))
        }
        return lines.joined(separator: "\n")
    }

    private struct Stats {
        let count: Int
        let min: Double
        let max: Double
        let avg: Double
        let p50: Double
        let p90: Double
        let p95: Double
        let p99: Double
    }

    private static func stats(_ values: [Double]) -> Stats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        let avg = sorted.reduce(0, +) / Double(n)
        func p(_ pct: Double) -> Double {
            // Nearest-rank percentile. 0.0 → first, 1.0 → last.
            let idx = max(0, min(n - 1, Int((Double(n - 1) * pct).rounded())))
            return sorted[idx]
        }
        return Stats(
            count: n,
            min: sorted.first!,
            max: sorted.last!,
            avg: avg,
            p50: p(0.50),
            p90: p(0.90),
            p95: p(0.95),
            p99: p(0.99)
        )
    }

    private static func formatStatsBlock(_ s: Stats, unit: String) -> [String] {
        return [
            String(format: "  min  %7.2f %@", s.min, unit),
            String(format: "  avg  %7.2f %@", s.avg, unit),
            String(format: "  p50  %7.2f %@", s.p50, unit),
            String(format: "  p90  %7.2f %@", s.p90, unit),
            String(format: "  p95  %7.2f %@", s.p95, unit),
            String(format: "  p99  %7.2f %@", s.p99, unit),
            String(format: "  max  %7.2f %@", s.max, unit),
        ]
    }
}

struct ArrivalSample: Identifiable, Hashable {
    let at: Date
    let deltaMs: Double
    let jitterMs: Double
    /// Stable identity by absolute time — we never reuse a timestamp
    /// for two different packets.
    var id: TimeInterval { at.timeIntervalSinceReferenceDate }
}
