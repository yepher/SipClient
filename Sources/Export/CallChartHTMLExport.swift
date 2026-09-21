import Foundation

/// Builds a single self-contained HTML file holding a call's charts, its
/// waveform and the recording itself, so a call can be handed to someone
/// who doesn't have this app.
///
/// Everything is inlined — sample data, waveform envelope, the WAV as a
/// base64 data URI, and the drawing code. No CDN, no sibling files, no
/// network: the export has to keep working when it arrives as an email
/// attachment on a machine that has never heard of this project.
enum CallChartHTMLExport {

    /// Raw WAV larger than this is left out rather than producing an
    /// unshareable file. Base64 inflates by about a third on top.
    static let audioEmbedLimit = 100 * 1024 * 1024

    struct Result {
        let html: String
        /// Set when the recording was too large to inline.
        let audioOmittedBytes: Int?
    }

    static func build(snapshot: CallChartSnapshot,
                      envelope: WaveformEnvelope?,
                      audioURL: URL?) -> Result {
        let samples = snapshot.samples
        let callStart = samples.first?.at ?? snapshot.endedAt
        let duration = (samples.last?.at ?? callStart).timeIntervalSince(callStart)

        // Sample series as three parallel arrays — far smaller than an
        // array of objects once there are a few thousand packets.
        var ts = [String](), ds = [String](), js = [String]()
        ts.reserveCapacity(samples.count)
        for s in samples {
            ts.append(trim(s.at.timeIntervalSince(callStart), places: 4))
            ds.append(trim(s.deltaMs, places: 2))
            js.append(trim(s.jitterMs, places: 2))
        }

        // Waveform envelope, quantised to signed bytes. At 3000 buckets
        // that is ~12 KB of JSON versus megabytes of raw samples, and it
        // is finer than any screen the export will be viewed on.
        var wave = "null"
        var audioOffset = 0.0
        if let env = envelope, let start = snapshot.recordingStartedAt {
            audioOffset = start.timeIntervalSince(callStart)
            let target = 3000
            let step = max(1, env.buckets.count / target)
            var nMin = [String](), nMax = [String](), fMin = [String](), fMax = [String]()
            var i = 0
            while i < env.buckets.count {
                let hi = min(i + step, env.buckets.count)
                var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0
                for k in i..<hi {
                    let bk = env.buckets[k]
                    if bk.nearMin < a { a = bk.nearMin }
                    if bk.nearMax > b { b = bk.nearMax }
                    if bk.farMin  < c { c = bk.farMin }
                    if bk.farMax  > d { d = bk.farMax }
                }
                nMin.append(q(a)); nMax.append(q(b))
                fMin.append(q(c)); fMax.append(q(d))
                i += step
            }
            let secs = env.secondsPerBucket * Double(step)
            wave = """
            {"dt":\(trim(secs, places: 6)),"mono":\(env.isMono),
             "nMin":[\(nMin.joined(separator: ","))],
             "nMax":[\(nMax.joined(separator: ","))],
             "fMin":[\(fMin.joined(separator: ","))],
             "fMax":[\(fMax.joined(separator: ","))]}
            """
        }

        // Audio, inlined as a data URI.
        var audioSrc = "null"
        var omitted: Int? = nil
        if let url = audioURL, let data = try? Data(contentsOf: url) {
            if data.count <= audioEmbedLimit {
                audioSrc = "\"data:audio/wav;base64,"
                         + data.base64EncodedString() + "\""
            } else {
                omitted = data.count
            }
        }

        let title = "Call Charts — " + absStamp.string(from: callStart)
        let meta = "\(samples.count) samples · "
                 + String(format: "%.1f s", duration)
                 + " · " + absStamp.string(from: callStart)

        let html = page(
            title: escape(title),
            meta: escape(meta),
            nominal: trim(snapshot.nominalDeltaMs, places: 2),
            duration: trim(duration, places: 4),
            audioOffset: trim(audioOffset, places: 4),
            ts: ts.joined(separator: ","),
            ds: ds.joined(separator: ","),
            js: js.joined(separator: ","),
            wave: wave,
            audioSrc: audioSrc,
            omittedNote: omitted.map {
                "Recording omitted — \($0 / 1_000_000) MB exceeds the "
                + "embed limit. The charts below are still accurate."
            } ?? ""
        )
        return Result(html: html, audioOmittedBytes: omitted)
    }

    // MARK: - Number formatting

    /// Fixed-point with trailing zeros stripped, so the JSON stays small.
    private static func trim(_ v: Double, places: Int) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.\(places)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s.isEmpty ? "0" : s
    }

    /// Quantise a -1…1 amplitude to a signed byte.
    private static func q(_ v: Float) -> String {
        String(Int(max(-1, min(1, v)) * 127))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let absStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
