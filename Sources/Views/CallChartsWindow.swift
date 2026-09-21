import AVFoundation
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

    // MARK: Recording playback

    /// What the audio lane is showing.
    enum LaneMode: String, CaseIterable, Identifiable {
        case waveform = "Waveform"
        case mfcc = "MFCC"
        var id: String { rawValue }
    }
    @State private var laneMode: LaneMode = .waveform

    /// Analysis of the call recording, nil until loaded (or if there is
    /// no recording for this call).
    @State private var analysis: RecordingAnalysis?
    /// Convenience accessor — the HTML export and waveform drawing both
    /// want just the envelope.
    private var envelope: WaveformEnvelope? { analysis?.envelope }
    /// Why the waveform couldn't be drawn, if it couldn't.
    @State private var waveformError: String?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    /// Playhead position in seconds from the start of the recording.
    @State private var playheadSeconds: Double = 0
    /// True while the export is being assembled, which can take a moment
    /// on a long call because the recording is base64'd into the page.
    @State private var isExporting = false

    /// A recording exists and is still on disk.
    private var recording: (url: URL, startedAt: Date)? {
        guard let url = snapshot.recordingURL,
              let start = snapshot.recordingStartedAt,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return (url, start)
    }

    /// Playhead as a point on the charts' shared time axis.
    private var playheadDate: Date? {
        guard let rec = recording else { return nil }
        return rec.startedAt.addingTimeInterval(playheadSeconds)
    }

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
            if let rec = recording {
                transport(rec)
                waveformLane(rec)
            }
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
        .task(id: snapshot.id) { await loadRecording() }
        .onDisappear { player?.stop() }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                    .autoconnect()) { _ in
            guard isPlaying, let p = player else { return }
            playheadSeconds = p.currentTime
            if !p.isPlaying { isPlaying = false }
        }
    }

    // MARK: - Recording

    private func loadRecording() async {
        guard let rec = recording else { return }
        player = try? AVAudioPlayer(contentsOf: rec.url)
        player?.prepareToPlay()
        // Scanning the whole file would block the window opening, so it
        // happens off the main actor and the lane appears when ready.
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<RecordingAnalysis, Error> in
            do { return .success(try RecordingAnalysis.load(url: rec.url)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let a): analysis = a
        case .failure(let err): waveformError = err.localizedDescription
        }
    }

    // MARK: - Export

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue =
            "call-charts-\(Self.fileStamp.string(from: snapshot.endedAt)).html"
        panel.canCreateDirectories = true
        panel.title = "Export Call Charts"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        let snap = snapshot
        let env = envelope
        let audio = recording?.url
        Task {
            // Base64'ing the recording is slow enough to freeze the window
            // on a long call, so build the page off the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                CallChartHTMLExport.build(snapshot: snap,
                                          envelope: env,
                                          audioURL: audio)
            }.value
            do {
                try result.html.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                if let omitted = result.audioOmittedBytes {
                    warn("Charts exported, but the recording was left out",
                         "The recording is \(omitted / 1_000_000) MB, over the "
                         + "limit for embedding in a shareable page. "
                         + "Send the .wav alongside it instead.")
                }
            } catch {
                warn("Could not write the export", error.localizedDescription)
            }
            isExporting = false
        }
    }

    private func warn(_ message: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = .warning
        a.runModal()
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private func togglePlayback() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            // Restart from the top once the end has been reached.
            if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
            p.play()
            isPlaying = true
        }
    }

    /// Move the playhead to a point on the time axis, clamped to the file.
    private func seek(to date: Date) {
        guard let rec = recording, let p = player else { return }
        let t = max(0, min(p.duration, date.timeIntervalSince(rec.startedAt)))
        p.currentTime = t
        playheadSeconds = t
    }

    private func clockString(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    @ViewBuilder
    private func transport(_ rec: (url: URL, startedAt: Date)) -> some View {
        HStack(spacing: 10) {
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .disabled(player == nil)
            .keyboardShortcut(.space, modifiers: [])
            .help(isPlaying ? "Pause (space)" : "Play recording (space)")

            Text("\(clockString(playheadSeconds)) / "
                 + "\(clockString(player?.duration ?? 0))")
                .font(.caption)
                .monospacedDigit()

            Text("left = us · right = peer · click a chart to move the playhead")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([rec.url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .help(rec.url.path)
        }
    }

    /// The waveform lane. Marks in the Chart are only the rules and the
    /// zoom rectangle — the waveform itself is stroked into the chart
    /// background, because one mark per pixel per channel would bring
    /// Swift Charts to a crawl on a call of any length.
    @ViewBuilder
    private func waveformLane(_ rec: (url: URL, startedAt: Date)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Picker("", selection: $laneMode) {
                    ForEach(LaneMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help(laneMode == .waveform
                      ? "Amplitude over time"
                      : "Mel-frequency cepstral coefficients — spectral "
                        + "shape over time, low coefficients at the bottom")
                if analysis == nil && waveformError == nil {
                    Text("analysing recording…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let err = waveformError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                }
                if laneMode == .mfcc, analysis?.mfccHopSeconds == nil,
                   analysis != nil {
                    Text("recording too short for MFCC")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if laneMode == .waveform {
                    Text("us").font(.caption2).foregroundStyle(.green)
                    Text("peer").font(.caption2).foregroundStyle(.purple)
                } else {
                    Text("us (top) · peer (bottom)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Chart {
                if let s = hoverSample {
                    RuleMark(x: .value("Hover", s.at))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                if let p = playheadDate {
                    RuleMark(x: .value("Playhead", p))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if let drag = dragRange {
                    RectangleMark(
                        xStart: .value("Zoom start", min(drag.start, drag.end)),
                        xEnd: .value("Zoom end", max(drag.start, drag.end)),
                        yStart: nil, yEnd: nil
                    )
                    .foregroundStyle(.blue.opacity(0.15))
                }
            }
            .chartXScale(domain: visibleDomain)
            .chartYScale(domain: -1.0 ... 1.0)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .chartPlotStyle { $0.clipped() }
            .chartBackground { proxy in
                GeometryReader { geo in
                    let frame = geo[proxy.plotAreaFrame]
                    Canvas { ctx, _ in
                        switch laneMode {
                        case .waveform:
                            drawWaveform(ctx, in: frame, start: rec.startedAt)
                        case .mfcc:
                            drawMFCC(ctx, in: frame, start: rec.startedAt)
                        }
                    }
                }
            }
            .chartOverlay { proxy in interactionLayer(proxy: proxy) }
            .frame(height: 104)
        }
    }

    /// Blit the pre-rendered MFCC heatmaps, near end on top and far end
    /// below, positioned so the images line up with the shared time axis.
    ///
    /// The images cover the whole recording, so zooming is expressed by
    /// drawing them into a wider destination rect and clipping — no
    /// re-rasterising per frame, which keeps playback smooth.
    private func drawMFCC(_ ctx: GraphicsContext, in frame: CGRect,
                          start: Date) {
        guard let a = analysis, a.mfccHopSeconds != nil else {
            let text = Text(analysis == nil ? "Analysing…"
                                            : "Recording too short for MFCC")
                .font(.caption).foregroundStyle(.secondary)
            ctx.draw(text, at: CGPoint(x: frame.midX, y: frame.midY))
            return
        }
        let lo = visibleDomain.lowerBound
        let span = visibleDomain.upperBound.timeIntervalSince(lo)
        guard span > 0, frame.width > 1, a.duration > 0 else { return }

        // Where the recording's start and end land in the visible window.
        let x0 = frame.minX + CGFloat((start.timeIntervalSince(lo) / span))
                              * frame.width
        let w  = CGFloat(a.duration / span) * frame.width
        guard w.isFinite, w > 0 else { return }

        let gap: CGFloat = 3
        let laneH = (frame.height - gap) / 2
        var c = ctx
        c.clip(to: Path(frame))
        if let near = a.mfccNear {
            c.draw(Image(decorative: near, scale: 1),
                   in: CGRect(x: x0, y: frame.minY, width: w, height: laneH))
        }
        if let far = a.mfccFar {
            c.draw(Image(decorative: far, scale: 1),
                   in: CGRect(x: x0, y: frame.minY + laneH + gap,
                              width: w, height: laneH))
        }
    }

    /// Stroke one vertical min/max segment per horizontal pixel, near end
    /// in the top half and far end in the bottom half.
    private func drawWaveform(_ ctx: GraphicsContext, in frame: CGRect,
                              start: Date) {
        let nearMid = frame.minY + frame.height * 0.25
        let farMid  = frame.minY + frame.height * 0.75
        let half    = frame.height * 0.22

        // Baselines, so silence still reads as a channel rather than a gap.
        var base = Path()
        base.move(to: CGPoint(x: frame.minX, y: nearMid))
        base.addLine(to: CGPoint(x: frame.maxX, y: nearMid))
        base.move(to: CGPoint(x: frame.minX, y: farMid))
        base.addLine(to: CGPoint(x: frame.maxX, y: farMid))
        ctx.stroke(base, with: .color(.gray.opacity(0.35)), lineWidth: 0.5)

        guard let env = envelope, frame.width > 1 else { return }
        let lo = visibleDomain.lowerBound
        let span = visibleDomain.upperBound.timeIntervalSince(lo)
        guard span > 0 else { return }

        let steps = Int(frame.width)
        var nearPath = Path(), farPath = Path()
        let offset = lo.timeIntervalSince(start)
        for px in 0..<steps {
            let t0 = offset + span * Double(px) / Double(steps)
            let t1 = offset + span * Double(px + 1) / Double(steps)
            guard t1 > 0, t0 < env.duration else { continue }
            let p = env.peaks(fromSeconds: max(0, t0),
                              toSeconds: min(env.duration, t1))
            let x = frame.minX + CGFloat(px) + 0.5
            nearPath.move(to: CGPoint(x: x, y: nearMid - CGFloat(p.near.1) * half))
            nearPath.addLine(to: CGPoint(x: x, y: nearMid - CGFloat(p.near.0) * half))
            if !env.isMono {
                farPath.move(to: CGPoint(x: x, y: farMid - CGFloat(p.far.1) * half))
                farPath.addLine(to: CGPoint(x: x, y: farMid - CGFloat(p.far.0) * half))
            }
        }
        ctx.stroke(nearPath, with: .color(.green.opacity(0.9)), lineWidth: 1)
        ctx.stroke(farPath, with: .color(.purple.opacity(0.9)), lineWidth: 1)
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
            Button {
                exportHTML()
            } label: {
                Label("Export HTML…", systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting)
            .help("Write a self-contained HTML file with the charts and "
                  + "the recording embedded, for sharing")
            .keyboardShortcut("e", modifiers: [.command])
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
                if let p = playheadDate {
                    RuleMark(x: .value("Playhead", p))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
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
                // Hover already tracks the pointer, so a plain click can
                // reuse it to place the playhead. The drag gesture below
                // has a 4pt minimum, so this doesn't fight zooming.
                .onTapGesture {
                    if let h = hoverDate { seek(to: h) }
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
