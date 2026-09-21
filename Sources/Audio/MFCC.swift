import Accelerate
import Foundation

/// Mel-frequency cepstral coefficients for one channel of a recording.
///
/// The call charts can show this instead of the waveform. A waveform only
/// tells you *how loud* the audio was at a moment; MFCCs say something
/// about its spectral shape, so a codec artefact, a burst of comfort
/// noise or a stretch of packet-loss fill looks different from speech
/// even when their amplitudes are similar.
///
/// Pipeline is the conventional one (3GPP/HTK style): Hamming-windowed
/// frames → real FFT → power spectrum → triangular mel filterbank →
/// log → DCT-II.
enum MFCC {

    struct Result {
        /// [frameIndex][coefficient]. Frames are `hopSeconds` apart.
        var frames: [[Float]]
        var coefficientCount: Int
        var hopSeconds: Double
        /// Symmetric display bound, derived from a high percentile of
        /// |value| so a single outlier can't flatten the colour scale.
        var displayScale: Float

        var isEmpty: Bool { frames.isEmpty }
    }

    /// Compute MFCCs for one channel.
    ///
    /// `coefficientCount` counts coefficients *after* c0, which is
    /// dropped: c0 is just overall frame energy, and on a diverging
    /// colour scale it dominates everything else into invisibility. The
    /// waveform view already answers "how loud".
    static func compute(samples: [Float],
                        sampleRate: Double,
                        windowSeconds: Double = 0.025,
                        hopSeconds: Double = 0.010,
                        filterCount: Int = 26,
                        coefficientCount: Int = 12) -> Result {
        let windowSamples = max(16, Int(windowSeconds * sampleRate))
        let hop = max(1, Int(hopSeconds * sampleRate))
        let fftSize = nextPowerOfTwo(windowSamples)
        let bins = fftSize / 2
        guard samples.count >= windowSamples, bins > 0 else {
            return Result(frames: [], coefficientCount: coefficientCount,
                          hopSeconds: hopSeconds, displayScale: 1)
        }

        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Result(frames: [], coefficientCount: coefficientCount,
                          hopSeconds: hopSeconds, displayScale: 1)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: windowSamples)
        vDSP_hamm_window(&window, vDSP_Length(windowSamples), 0)

        let bank = melFilterbank(filterCount: filterCount, bins: bins,
                                 sampleRate: sampleRate)
        let dct = dctMatrix(coefficientCount: coefficientCount,
                            filterCount: filterCount)

        var padded = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: bins)
        var imag = [Float](repeating: 0, count: bins)
        var power = [Float](repeating: 0, count: bins)
        var logEnergies = [Float](repeating: 0, count: filterCount)

        let frameCount = 1 + (samples.count - windowSamples) / hop
        var out = [[Float]]()
        out.reserveCapacity(frameCount)

        for f in 0..<frameCount {
            let start = f * hop
            // Window into a zero-padded FFT-sized buffer.
            for i in 0..<fftSize { padded[i] = 0 }
            vDSP_vmul(Array(samples[start..<(start + windowSamples)]), 1,
                      window, 1, &padded, 1, vDSP_Length(windowSamples))

            padded.withUnsafeBufferPointer { pad in
                pad.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                   capacity: bins) { cplx in
                    real.withUnsafeMutableBufferPointer { rp in
                        imag.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                        imagp: ip.baseAddress!)
                            vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(bins))
                            vDSP_fft_zrip(setup, &split, 1, log2n,
                                          FFTDirection(FFT_FORWARD))
                            // zrip packs Nyquist into imag[0]; leaving it
                            // there would fold the top of the spectrum
                            // into the DC bin.
                            ip[0] = 0
                            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(bins))
                        }
                    }
                }
            }

            // Filterbank + log. vDSP_fft_zrip carries a constant factor-of-2
            // scaling which log turns into a constant offset, and the DCT
            // then removes it from every coefficient above c0 — so there is
            // no need to normalise it away here.
            for j in 0..<filterCount {
                var acc: Float = 0
                let filt = bank[j]
                for (bin, weight) in filt { acc += power[bin] * weight }
                logEnergies[j] = log(max(acc, 1e-10))
            }

            var coeffs = [Float](repeating: 0, count: coefficientCount)
            for k in 0..<coefficientCount {
                var acc: Float = 0
                let row = dct[k]
                for j in 0..<filterCount { acc += logEnergies[j] * row[j] }
                coeffs[k] = acc
            }
            out.append(coeffs)
        }

        return Result(frames: out,
                      coefficientCount: coefficientCount,
                      hopSeconds: Double(hop) / sampleRate,
                      displayScale: robustScale(out))
    }

    // MARK: - Pieces (internal so they can be checked directly)

    static func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    static func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

    /// Triangular mel filters as sparse (bin, weight) lists.
    static func melFilterbank(filterCount: Int, bins: Int,
                              sampleRate: Double,
                              lowHz: Double = 20) -> [[(Int, Float)]] {
        let highHz = sampleRate / 2
        let melLow = hzToMel(lowHz), melHigh = hzToMel(highHz)
        // filterCount + 2 points: each filter spans one point either side.
        let points = (0...(filterCount + 1)).map { i -> Double in
            melToHz(melLow + (melHigh - melLow) * Double(i) / Double(filterCount + 1))
        }
        let binHz = highHz / Double(bins)
        var bank = [[(Int, Float)]]()
        bank.reserveCapacity(filterCount)
        for j in 0..<filterCount {
            let lo = points[j], mid = points[j + 1], hi = points[j + 2]
            var filt = [(Int, Float)]()
            let binLo = max(0, Int(floor(lo / binHz)))
            let binHi = min(bins - 1, Int(ceil(hi / binHz)))
            if binLo <= binHi {
                for b in binLo...binHi {
                    let hz = Double(b) * binHz
                    var w = 0.0
                    if hz >= lo && hz <= mid && mid > lo {
                        w = (hz - lo) / (mid - lo)
                    } else if hz > mid && hz <= hi && hi > mid {
                        w = (hi - hz) / (hi - mid)
                    }
                    if w > 0 { filt.append((b, Float(w))) }
                }
            }
            bank.append(filt)
        }
        return bank
    }

    /// DCT-II rows for coefficients 1…coefficientCount (c0 excluded).
    static func dctMatrix(coefficientCount: Int, filterCount: Int) -> [[Float]] {
        (0..<coefficientCount).map { k in
            let order = k + 1            // skip c0
            return (0..<filterCount).map { j in
                Float(cos(Double.pi * Double(order)
                          * (Double(j) + 0.5) / Double(filterCount)))
            }
        }
    }

    /// 98th percentile of |value|, so the colour scale isn't set by one
    /// transient. Falls back to 1 for degenerate input.
    private static func robustScale(_ frames: [[Float]]) -> Float {
        var all = [Float]()
        all.reserveCapacity(frames.count * (frames.first?.count ?? 0))
        for f in frames { for v in f { all.append(abs(v)) } }
        guard !all.isEmpty else { return 1 }
        all.sort()
        let idx = min(all.count - 1, Int(Double(all.count) * 0.98))
        let s = all[idx]
        return s > 1e-6 ? s : 1
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}
