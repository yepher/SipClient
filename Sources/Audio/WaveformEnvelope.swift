import Foundation

/// A min/max envelope of a recorded call, used to draw the waveform lane
/// in the call charts.
///
/// Drawing from raw samples would be hopeless — even a short call is
/// hundreds of thousands of samples per channel — so the file is reduced
/// once to fixed-width buckets holding the peak excursion in each, which
/// is what a waveform display actually needs. Everything is normalised to
/// -1…1 so the drawing code never has to care about bit depth.
struct WaveformEnvelope {
    /// Peak excursion within one time bucket, per channel, normalised.
    struct Bucket {
        var nearMin: Float
        var nearMax: Float
        var farMin: Float
        var farMax: Float
    }

    let buckets: [Bucket]
    let secondsPerBucket: Double
    let duration: TimeInterval
    /// True when the file was mono, in which case the far-end values are
    /// zero and only the near lane is meaningful.
    let isMono: Bool

    enum LoadError: Error, LocalizedError {
        case tooLarge(bytes: Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .tooLarge(let b):
                return "Recording is too large to plot "
                     + "(\(b / 1_000_000) MB)"
            case .empty:
                return "Recording contains no audio"
            }
        }
    }

    /// Read a recording and reduce it to an envelope.
    ///
    /// `targetBucketSeconds` is the resolution we aim for; `maxBuckets`
    /// caps memory on long calls, at which point resolution degrades
    /// rather than the load failing. Call this off the main thread — it
    /// reads and scans the whole file.
    static func load(url: URL,
                     targetBucketSeconds: Double = 0.002,
                     maxBuckets: Int = 200_000,
                     byteLimit: Int = 400_000_000) throws -> WaveformEnvelope {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > byteLimit {
            throw LoadError.tooLarge(bytes: size)
        }

        let loaded = try WAVFile.read(url: url)
        let channels = max(1, Int(loaded.channels))
        let frameCount = loaded.samples.count / channels
        guard frameCount > 0, loaded.sampleRate > 0 else { throw LoadError.empty }

        let rate = Double(loaded.sampleRate)
        let duration = Double(frameCount) / rate
        // Frames per bucket, widened if that would exceed the cap.
        var framesPerBucket = max(1, Int(targetBucketSeconds * rate))
        if frameCount / framesPerBucket > maxBuckets {
            framesPerBucket = max(1, frameCount / maxBuckets)
        }
        let bucketCount = max(1, frameCount / framesPerBucket)

        let scale = Float(Int16.max)
        var out = [Bucket](repeating: Bucket(nearMin: 0, nearMax: 0,
                                             farMin: 0, farMax: 0),
                           count: bucketCount)
        loaded.samples.withUnsafeBufferPointer { s in
            for b in 0..<bucketCount {
                let start = b * framesPerBucket
                let end = min(start + framesPerBucket, frameCount)
                var nMin: Int16 = 0, nMax: Int16 = 0
                var fMin: Int16 = 0, fMax: Int16 = 0
                for f in start..<end {
                    let n = s[f * channels]
                    if n < nMin { nMin = n }
                    if n > nMax { nMax = n }
                    if channels > 1 {
                        let fv = s[f * channels + 1]
                        if fv < fMin { fMin = fv }
                        if fv > fMax { fMax = fv }
                    }
                }
                out[b] = Bucket(nearMin: Float(nMin) / scale,
                                nearMax: Float(nMax) / scale,
                                farMin: Float(fMin) / scale,
                                farMax: Float(fMax) / scale)
            }
        }

        return WaveformEnvelope(
            buckets: out,
            secondsPerBucket: Double(framesPerBucket) / rate,
            duration: duration,
            isMono: channels < 2
        )
    }

    /// Peak excursion across a time span, as (min, max) per channel.
    ///
    /// Zoomed all the way out a single pixel can cover thousands of
    /// buckets, so the scan is strided to a bounded number of probes.
    /// That can clip a lone extreme sample, which is invisible at that
    /// zoom level and keeps redraws cheap enough to stay interactive.
    func peaks(fromSeconds: Double, toSeconds: Double,
               maxProbes: Int = 64) -> (near: (Float, Float), far: (Float, Float)) {
        guard !buckets.isEmpty else { return ((0, 0), (0, 0)) }
        let lo = max(0, Int(fromSeconds / secondsPerBucket))
        let hi = min(buckets.count, max(lo + 1, Int(toSeconds / secondsPerBucket)))
        guard lo < hi else { return ((0, 0), (0, 0)) }
        let stride = max(1, (hi - lo) / maxProbes)
        var nMin: Float = 0, nMax: Float = 0, fMin: Float = 0, fMax: Float = 0
        var i = lo
        while i < hi {
            let b = buckets[i]
            if b.nearMin < nMin { nMin = b.nearMin }
            if b.nearMax > nMax { nMax = b.nearMax }
            if b.farMin  < fMin { fMin = b.farMin }
            if b.farMax  > fMax { fMax = b.farMax }
            i += stride
        }
        return ((nMin, nMax), (fMin, fMax))
    }
}
