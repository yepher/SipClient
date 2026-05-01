import SwiftUI
import Charts

/// Top-level window contents resolved from a snapshot ID. Shown when
/// the user clicks "View In Call Chart" in the wire log. The
/// surrounding `WindowGroup` in `SipClientApp` carries the UUID; this
/// view looks the snapshot up in `AppState` and either renders the
/// charts or shows a not-found placeholder if the log was cleared.
struct CallChartsWindow: View {
    @EnvironmentObject var appState: AppState
    let snapshotID: UUID?

    var body: some View {
        Group {
            if let id = snapshotID, let snap = appState.callChart(id: id) {
                CallChartsView(snapshot: snap)
            } else {
                ContentUnavailableView(
                    "No chart data",
                    systemImage: "chart.line.downtrend.xyaxis",
                    description: Text("This call's chart data was cleared "
                                      + "or the snapshot couldn't be found.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// Renders the full-call delta + jitter charts with drag-to-zoom and
/// a hover crosshair that prints discrete sample values.
struct CallChartsView: View {
    let snapshot: CallChartSnapshot

    /// Currently displayed x-axis range. Nil → full range. Drag-select
    /// inside a chart to zoom to a sub-range; press Reset to clear.
    @State private var xDomain: ClosedRange<Date>?
    /// In-progress drag region (start, current). Drawn as a rect overlay
    /// while the user is selecting.
    @State private var dragRange: (start: Date, end: Date)?
    /// Date currently under the mouse pointer. Drives the crosshair +
    /// readout above the charts.
    @State private var hoverDate: Date?

    private var visibleDomain: ClosedRange<Date> {
        if let d = xDomain { return d }
        if let r = snapshot.fullRange { return r }
        let now = Date()
        return now...now.addingTimeInterval(1)
    }

    private var visibleSamples: [ArrivalSample] {
        let d = visibleDomain
        return snapshot.samples.filter { $0.at >= d.lowerBound && $0.at <= d.upperBound }
    }

    private var hoverSample: ArrivalSample? {
        guard let h = hoverDate else { return nil }
        return nearestSample(to: h, in: visibleSamples)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            Divider()
            hoverReadout
            chart(
                title: "Δ inter-arrival (ms) — ideal "
                     + "\(Int(snapshot.nominalDeltaMs)) ms",
                titleColor: .blue,
                referenceY: snapshot.nominalDeltaMs,
                lineColor: .blue,
                value: { $0.deltaMs },
                yMaxFloor: snapshot.nominalDeltaMs * 2
            )
            chart(
                title: "Jitter (ms) — ideal 0 ms",
                titleColor: .orange,
                referenceY: 0,
                lineColor: .orange,
                value: { $0.jitterMs },
                yMaxFloor: 10
            )
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Call Charts").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset zoom") {
                xDomain = nil
                dragRange = nil
            }
            .disabled(xDomain == nil)
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    private var subtitle: String {
        var parts: [String] = ["\(snapshot.samples.count) samples"]
        if let r = snapshot.fullRange {
            let secs = r.upperBound.timeIntervalSince(r.lowerBound)
            parts.append(String(format: "%.1f s", secs))
        }
        if xDomain != nil {
            let secs = visibleDomain.upperBound
                .timeIntervalSince(visibleDomain.lowerBound)
            parts.append(String(format: "zoomed: %.2f s", secs))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var hoverReadout: some View {
        // Always present even when nil so the layout doesn't jump; we
        // just dim the placeholder text.
        HStack(spacing: 14) {
            if let s = hoverSample {
                Text(timeLabel(for: s.at))
                    .monospacedDigit()
                Text(String(format: "Δ %.2f ms", s.deltaMs))
                    .monospacedDigit()
                    .foregroundStyle(.blue)
                Text(String(format: "jit %.2f ms", s.jitterMs))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            } else {
                Text("Hover a chart to see values · drag to zoom")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
    }

    /// Format relative to the call's first sample if we have one,
    /// otherwise fall back to wall-clock H:m:s.SSS.
    private func timeLabel(for at: Date) -> String {
        if let start = snapshot.firstSampleAt {
            let secs = at.timeIntervalSince(start)
            return String(format: "t %+.3f s", secs)
        }
        return Self.absFormatter.string(from: at)
    }

    private static let absFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    @ViewBuilder
    private func chart(
        title: String,
        titleColor: Color,
        referenceY: Double,
        lineColor: Color,
        value: @escaping (ArrivalSample) -> Double,
        yMaxFloor: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(titleColor)
            Chart {
                RuleMark(y: .value(title, referenceY))
                    .foregroundStyle(.green.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(snapshot.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.at),
                        y: .value(title, value(sample))
                    )
                    .foregroundStyle(lineColor)
                }
                if let s = hoverSample {
                    RuleMark(x: .value("Hover", s.at))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(
                        x: .value("Hover", s.at),
                        y: .value(title, value(s))
                    )
                    .foregroundStyle(lineColor)
                    .symbolSize(60)
                }
                if let drag = dragRange {
                    let lo = min(drag.start, drag.end)
                    let hi = max(drag.start, drag.end)
                    RectangleMark(
                        xStart: .value("Zoom start", lo),
                        xEnd: .value("Zoom end", hi),
                        yStart: nil,
                        yEnd: nil
                    )
                    .foregroundStyle(.blue.opacity(0.15))
                }
            }
            .chartXScale(domain: visibleDomain)
            .chartYScale(domain: 0 ... yMax(for: value, floor: yMaxFloor))
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in
                interactionLayer(proxy: proxy)
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        }
    }

    /// Y-axis upper bound: max observed value within the visible window
    /// + 20 % headroom, with a floor so flat data still renders cleanly.
    private func yMax(for value: (ArrivalSample) -> Double,
                      floor: Double) -> Double {
        let v = visibleSamples.map(value).max() ?? 0
        return max(floor, v * 1.2)
    }

    @ViewBuilder
    private func interactionLayer(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let plotFrame = geo[proxy.plotAreaFrame]
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        let x = pt.x - plotFrame.origin.x
                        if let date: Date = proxy.value(atX: x) {
                            hoverDate = date
                        }
                    case .ended:
                        hoverDate = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            let xs = v.startLocation.x - plotFrame.origin.x
                            let xe = v.location.x - plotFrame.origin.x
                            if let s: Date = proxy.value(atX: xs),
                               let e: Date = proxy.value(atX: xe) {
                                dragRange = (s, e)
                            }
                        }
                        .onEnded { v in
                            let xs = v.startLocation.x - plotFrame.origin.x
                            let xe = v.location.x - plotFrame.origin.x
                            defer { dragRange = nil }
                            guard let s: Date = proxy.value(atX: xs),
                                  let e: Date = proxy.value(atX: xe)
                            else { return }
                            let lo = min(s, e), hi = max(s, e)
                            // Reject tiny drags so a stray click doesn't
                            // collapse the view to a slice of nothing.
                            guard hi.timeIntervalSince(lo) > 0.05 else {
                                return
                            }
                            xDomain = lo...hi
                        }
                )
        }
    }

    private func nearestSample(to date: Date,
                               in samples: [ArrivalSample]) -> ArrivalSample? {
        guard !samples.isEmpty else { return nil }
        // Binary search would be nicer; linear is fine for the chart's
        // scale (up to a few thousand visible samples).
        var best = samples[0]
        var bestDist = abs(best.at.timeIntervalSince(date))
        for s in samples.dropFirst() {
            let d = abs(s.at.timeIntervalSince(date))
            if d < bestDist {
                best = s; bestDist = d
            }
        }
        return best
    }
}
