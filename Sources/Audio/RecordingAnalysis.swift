import CoreGraphics
import Foundation

/// Everything the call charts need from a recording, produced in a single
/// pass over the file.
///
/// The waveform envelope and the MFCCs both want the decoded samples, and
/// the samples are the expensive part — a few minutes of stereo 16 kHz is
/// tens of megabytes. Reading once and deriving both keeps that cost paid
/// exactly once, and lets the samples go out of scope immediately after.
struct RecordingAnalysis {
    let envelope: WaveformEnvelope
    /// Pre-rendered MFCC heatmaps, near end and far end. Rendering to an
    /// image up front means drawing is one blit per redraw instead of
    /// thousands of rects — which matters because the playhead redraws
    /// the whole lane every frame during playback.
    let mfccNear: CGImage?
    let mfccFar: CGImage?
    /// Nil when MFCCs could not be produced (recording too short).
    let mfccHopSeconds: Double?
    let duration: TimeInterval

    static func load(url: URL) throws -> RecordingAnalysis {
        let loaded = try WAVFile.read(url: url)
        let envelope = try WaveformEnvelope.build(from: loaded)
        let channels = max(1, Int(loaded.channels))
        let rate = Double(loaded.sampleRate)
        let frameCount = loaded.samples.count / channels

        func channelSamples(_ index: Int) -> [Float] {
            var out = [Float](repeating: 0, count: frameCount)
            let scale = Float(Int16.max)
            loaded.samples.withUnsafeBufferPointer { s in
                for f in 0..<frameCount { out[f] = Float(s[f * channels + index]) / scale }
            }
            return out
        }

        let near = MFCC.compute(samples: channelSamples(0), sampleRate: rate)
        let far: MFCC.Result? = channels > 1
            ? MFCC.compute(samples: channelSamples(1), sampleRate: rate)
            : nil

        return RecordingAnalysis(
            envelope: envelope,
            mfccNear: heatmap(near),
            mfccFar: far.flatMap(heatmap),
            mfccHopSeconds: near.isEmpty ? nil : near.hopSeconds,
            duration: envelope.duration)
    }

    /// Render an MFCC result as an image: one column per frame, one row
    /// per coefficient, low coefficients at the bottom.
    ///
    /// The colour ramp is diverging — blue for negative, near-black at
    /// zero, orange for positive — reusing the palette the Δ and jitter
    /// charts already use so the three lanes read as one instrument.
    static func heatmap(_ r: MFCC.Result) -> CGImage? {
        guard !r.frames.isEmpty, r.coefficientCount > 0 else { return nil }
        // Very long calls would otherwise build an image wider than
        // CoreGraphics will accept; averaging columns degrades detail
        // rather than failing outright.
        let maxWidth = 16384
        let stride = max(1, (r.frames.count + maxWidth - 1) / maxWidth)
        let width = (r.frames.count + stride - 1) / stride
        let height = r.coefficientCount
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let scale = max(r.displayScale, 1e-6)

        for x in 0..<width {
            let lo = x * stride
            let hi = min(lo + stride, r.frames.count)
            for c in 0..<height {
                var acc: Float = 0
                for f in lo..<hi { acc += r.frames[f][c] }
                let v = max(-1, min(1, acc / Float(hi - lo) / scale))
                // Row 0 is the top of the image, so invert to put the
                // lowest coefficient along the bottom edge.
                let y = height - 1 - c
                let o = (y * width + x) * 4
                let (red, green, blue) = colour(v)
                pixels[o] = red; pixels[o + 1] = green
                pixels[o + 2] = blue; pixels[o + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue:
                            CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Diverging ramp over -1…1.
    private static func colour(_ v: Float) -> (UInt8, UInt8, UInt8) {
        let t = UInt8(min(255, max(0, abs(v) * 255)))
        if v < 0 {
            // toward blue (matches the Δ inter-arrival series)
            return (UInt8(Double(t) * 0.23), UInt8(Double(t) * 0.55), t)
        } else {
            // toward orange (matches the jitter series)
            return (t, UInt8(Double(t) * 0.57), UInt8(Double(t) * 0.18))
        }
    }
}
