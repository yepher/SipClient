import Foundation

/// G.722 sub-band ADPCM codec per ITU-T G.722.
///
/// Wideband (16 kHz) audio carried at 64 kbps. The 16 kHz signal is split
/// by a 24-tap QMF into two 8 kHz subbands; the lower is ADPCM-encoded at
/// 6 bits/sample, the upper at 2 bits/sample. Two PCM samples → one
/// encoded byte.
///
/// Tables and the adaptation block (`block4`) follow the ITU reference
/// implementation as preserved in spandsp's g722.c.

private let qmfCoeffs: [Int] = [
    3, -11, 12, 32, -210, 951, 3876, -805, 362, -156, 53, -11
]

private let q6: [Int] = [
    0, 35, 72, 110, 150, 190, 233, 276, 323, 370, 422, 473,
    530, 587, 650, 714, 786, 858, 940, 1023, 1121, 1219, 1339, 1458,
    1612, 1765, 1980, 2195, 2557, 2919, 0
]

private let iln: [Int] = [
    0, 63, 62, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19,
    18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 0
]

private let ilp: [Int] = [
    0, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48, 47,
    46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 0
]

private let wl: [Int] = [
    -60, -30, 58, 172, 334, 538, 1198, 3042
]

private let rl42: [Int] = [
    0, 7, 6, 5, 4, 3, 2, 1, 7, 6, 5, 4, 3, 2, 1, 0
]

private let ilb: [Int] = [
    2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383,
    2435, 2489, 2543, 2599, 2656, 2714, 2774, 2834,
    2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371,
    3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008
]

private let qm4: [Int] = [
    0, -20456, -12896, -8968, -6288, -4240, -2584, -1200,
    20456, 12896, 8968, 6288, 4240, 2584, 1200, 0
]

private let qm6: [Int] = [
    -136, -136, -136, -136,
    -24808, -21904, -19008, -16704, -14984, -13512, -12280, -11192,
    -10232, -9360, -8576, -7856, -7192, -6576, -6000, -5456,
    -4944, -4464, -4008, -3576, -3168, -2776, -2400, -2032,
    -1688, -1360, -1040, -728,
    24808, 21904, 19008, 16704, 14984, 13512, 12280, 11192,
    10232, 9360, 8576, 7856, 7192, 6576, 6000, 5456,
    4944, 4464, 4008, 3576, 3168, 2776, 2400, 2032,
    1688, 1360, 1040, 728, 432, 136, -432, -136
]

private let qm2: [Int] = [
    -7408, -1616, 7408, 1616
]

private let wh: [Int] = [
    0, -214, 798
]

private let rh2: [Int] = [
    2, 1, 2, 1
]

private let ihn: [Int] = [0, 1, 0]
private let ihp: [Int] = [0, 3, 2]

/// Saturate a 32-bit signed value to 16-bit signed range.
@inline(__always)
private func sat(_ x: Int) -> Int {
    if x > 32767 { return 32767 }
    if x < -32768 { return -32768 }
    return x
}

/// Implements `ilb[wd1] >> shift` allowing `shift` to be negative
/// (treated as a left shift by `-shift`). The ITU SCALEL formula
/// produces a negative shift at the top of the `nb` range.
@inline(__always)
private func ilbShifted(wd1: Int, shift: Int) -> Int {
    if shift >= 0 { return ilb[wd1] >> shift }
    return ilb[wd1] << -shift
}

/// Per-subband ADPCM state (poles, zeros, scale factor).
private struct BandState {
    var s: Int = 0
    var sp: Int = 0
    var sz: Int = 0
    var r: [Int] = [0, 0, 0]
    var a: [Int] = [0, 0, 0]
    var ap: [Int] = [0, 0, 0]
    var p: [Int] = [0, 0, 0]
    var d: [Int] = [0, 0, 0, 0, 0, 0, 0]
    var b: [Int] = [0, 0, 0, 0, 0, 0, 0]
    var bp: [Int] = [0, 0, 0, 0, 0, 0, 0]
    var sg: [Int] = [0, 0, 0, 0, 0, 0, 0]
    var nb: Int = 0
    var det: Int = 32

    /// ITU "Block 4": pole/zero predictor adaptation. `d` is the
    /// dequantizer output for this subband sample.
    mutating func block4(_ d: Int) {
        // RECONS / PARREC
        self.d[0] = d
        r[0] = sat(s + d)
        p[0] = sat(sz + d)

        // UPPOL2
        for i in 0..<3 { sg[i] = p[i] >> 15 }
        var wd1 = sat(a[1] << 2)
        var wd2 = (sg[0] == sg[1]) ? -wd1 : wd1
        if wd2 > 32767 { wd2 = 32767 }
        var wd3 = (wd2 >> 7) + ((sg[0] == sg[2]) ? 128 : -128)
        wd3 += (a[2] * 32512) >> 15
        if wd3 > 12288 { wd3 = 12288 }
        else if wd3 < -12288 { wd3 = -12288 }
        ap[2] = wd3

        // UPPOL1
        sg[0] = p[0] >> 15
        sg[1] = p[1] >> 15
        wd1 = (sg[0] == sg[1]) ? 192 : -192
        wd2 = (a[1] * 32640) >> 15
        ap[1] = sat(wd1 + wd2)
        let limit = sat(15360 - ap[2])
        if ap[1] > limit { ap[1] = limit }
        else if ap[1] < -limit { ap[1] = -limit }

        // UPZERO
        let inc = (d == 0) ? 0 : 128
        sg[0] = d >> 15
        for i in 1..<7 {
            sg[i] = self.d[i] >> 15
            let w2 = (sg[i] == sg[0]) ? inc : -inc
            let w3 = (b[i] * 32640) >> 15
            bp[i] = sat(w2 + w3)
        }

        // DELAYA
        for i in stride(from: 6, through: 1, by: -1) {
            self.d[i] = self.d[i - 1]
            b[i] = bp[i]
        }
        for i in stride(from: 2, through: 1, by: -1) {
            r[i] = r[i - 1]
            p[i] = p[i - 1]
            a[i] = ap[i]
        }

        // FILTEP
        var w1 = sat(r[1] + r[1])
        w1 = (a[1] * w1) >> 15
        var w2 = sat(r[2] + r[2])
        w2 = (a[2] * w2) >> 15
        sp = sat(w1 + w2)

        // FILTEZ
        var sumz = 0
        for i in stride(from: 6, through: 1, by: -1) {
            let wz = sat(self.d[i] + self.d[i])
            sumz += (b[i] * wz) >> 15
        }
        sz = sat(sumz)

        // PREDIC
        s = sat(sp + sz)
    }
}

// MARK: - Encoder

final class G722Encoder: CodecEncoder {
    private var low = BandState()
    private var high = BandState()
    private var x = [Int](repeating: 0, count: 24)

    func encode(pcm: [Int16]) -> Data {
        var out = Data(capacity: pcm.count / 2)
        var i = 0
        while i + 1 < pcm.count {
            // Slide QMF buffer by 2 (newest at low indices).
            for j in stride(from: 23, through: 2, by: -1) {
                x[j] = x[j - 2]
            }
            // G.722 expects 14-bit signed PCM in [-8192, 8191]. Standard
            // 16-bit PCM is shifted right by 2 for the codec's internal
            // arithmetic; samples are saturated.
            // G.722 expects ~15-bit linear PCM in the analysis filter;
            // standard 16-bit PCM is shifted right by 1.
            x[0] = Int(pcm[i + 1]) >> 1
            x[1] = Int(pcm[i]) >> 1
            i += 2

            // QMF analysis: even taps form low band sum, odd taps form
            // high band difference (after applying coefficients).
            var sumeven = 0
            var sumodd = 0
            for k in 0..<12 {
                sumeven += x[2 * k] * qmfCoeffs[k]
                sumodd  += x[2 * k + 1] * qmfCoeffs[11 - k]
            }
            let xL = (sumeven + sumodd) >> 13
            let xH = (sumeven - sumodd) >> 13

            let iL = encodeLowBand(sat(xL))
            let iH = encodeHighBand(sat(xH))
            out.append(UInt8((iH << 6) | (iL & 0x3F)))
        }
        return out
    }

    /// 6-bit ADPCM of the lower subband.
    private func encodeLowBand(_ xl: Int) -> Int {
        let el = sat(xl - low.s)
        let wd = (el >= 0) ? el : -(el + 1)

        // Quantize: find smallest mil such that wd < (q6[mil] * det) >> 12.
        var mil = 1
        while mil < 30 {
            let thresh = (q6[mil] * low.det) >> 12
            if wd < thresh { break }
            mil += 1
        }
        let il = (el < 0) ? iln[mil] : ilp[mil]

        // Inverse quantize (4-bit truncation of il) and update predictor.
        let ril = il >> 2
        let il4 = rl42[ril]
        let wd2 = (low.det * qm4[ril]) >> 15
        let dlt = wd2

        // Update scale factor
        var nb = (low.nb * 127) >> 7
        nb += wl[il4]
        if nb < 0 { nb = 0 }
        else if nb > 18432 { nb = 18432 }
        low.nb = nb
        low.det = ilbShifted(wd1: (nb >> 6) & 31, shift: 8 - (nb >> 11)) << 2

        low.block4(dlt)
        return il
    }

    /// 2-bit ADPCM of the upper subband.
    private func encodeHighBand(_ xh: Int) -> Int {
        let eh = sat(xh - high.s)
        let wd = (eh >= 0) ? eh : -(eh + 1)
        let mih = (wd >= ((564 * high.det) >> 12)) ? 2 : 1
        let ih = (eh < 0) ? ihn[mih] : ihp[mih]

        let ih2 = rh2[ih]
        let dh = (high.det * qm2[ih]) >> 15

        var nb = (high.nb * 127) >> 7
        nb += wh[ih2]
        if nb < 0 { nb = 0 }
        else if nb > 22528 { nb = 22528 }
        high.nb = nb
        high.det = ilbShifted(wd1: (nb >> 6) & 31, shift: 10 - (nb >> 11)) << 2

        high.block4(dh)
        return ih
    }
}

// MARK: - Decoder

final class G722Decoder: CodecDecoder {
    private var low = BandState()
    private var high = BandState()
    private var x = [Int](repeating: 0, count: 24)

    func decode(payload: Data) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(payload.count * 2)

        for byte in payload {
            let il = Int(byte) & 0x3F
            let ih = (Int(byte) >> 6) & 0x03

            let rl = decodeLowBand(il)
            let rh = decodeHighBand(ih)

            // Slide QMF buffer by 2 (newest at low indices).
            for j in stride(from: 23, through: 2, by: -1) {
                x[j] = x[j - 2]
            }
            x[0] = sat(rl + rh)
            x[1] = sat(rl - rh)

            // QMF synthesis uses the same coefficient layout as analysis:
            // even-indexed buffer × coeffs[k], odd-indexed × coeffs[11-k].
            var sumeven = 0
            var sumodd = 0
            for k in 0..<12 {
                sumeven += x[2 * k] * qmfCoeffs[k]
                sumodd  += x[2 * k + 1] * qmfCoeffs[11 - k]
            }
            // Output is ~15-bit; shift left by 1 to get back to Int16 range.
            let s0 = sat(sumeven >> 12)
            let s1 = sat(sumodd  >> 12)
            out.append(Int16(clamping: s0 << 1))
            out.append(Int16(clamping: s1 << 1))
        }
        return out
    }

    private func decodeLowBand(_ il: Int) -> Int {
        let ril = il >> 2
        let il4 = rl42[ril]
        let dlt = (low.det * qm4[ril]) >> 15
        let rl = sat(low.s + dlt)

        var nb = (low.nb * 127) >> 7
        nb += wl[il4]
        if nb < 0 { nb = 0 }
        else if nb > 18432 { nb = 18432 }
        low.nb = nb
        low.det = ilbShifted(wd1: (nb >> 6) & 31, shift: 8 - (nb >> 11)) << 2

        low.block4(dlt)
        return rl
    }

    private func decodeHighBand(_ ih: Int) -> Int {
        let ih2 = rh2[ih]
        let dh = (high.det * qm2[ih]) >> 15
        let rh = sat(high.s + dh)

        var nb = (high.nb * 127) >> 7
        nb += wh[ih2]
        if nb < 0 { nb = 0 }
        else if nb > 22528 { nb = 22528 }
        high.nb = nb
        high.det = ilbShifted(wd1: (nb >> 6) & 31, shift: 10 - (nb >> 11)) << 2

        high.block4(dh)
        return rh
    }
}
