import Foundation

/// Frozen, post-call view of the data needed to redraw the in-call
/// charts. CallMetrics itself is dropped when the call ends; we copy
/// out just the chart-relevant fields (samples + reference values +
/// timing milestones) so the wire log's "View In Call Chart" popout
/// can outlive the call.
struct CallChartSnapshot: Identifiable, Hashable {
    let id: UUID
    let samples: [ArrivalSample]
    let nominalDeltaMs: Double
    let inviteAt: Date?
    let answeredAt: Date?
    let firstAudioAt: Date?
    let endedAt: Date
    /// Recording of this call, when one was made. The charts overlay its
    /// waveform and offer playback.
    let recordingURL: URL?
    /// Wall-clock instant of the recording's first frame, which is what
    /// maps a position in the file onto the charts' time axis.
    let recordingStartedAt: Date?

    var firstSampleAt: Date? { samples.first?.at }
    var lastSampleAt: Date? { samples.last?.at }
    var fullRange: ClosedRange<Date>? {
        guard let first = firstSampleAt, let last = lastSampleAt, first <= last else {
            return nil
        }
        return first...last
    }

    static func == (lhs: CallChartSnapshot, rhs: CallChartSnapshot) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
