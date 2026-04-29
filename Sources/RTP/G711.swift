import Foundation

/// G.711 codec helpers — μ-law and A-law encode/decode for 8 kHz mono audio.
///
/// All functions use the standard ITU-T tables. PCM samples are 16-bit
/// signed (Int16), interpreted as linear; encoded bytes are 8-bit (UInt8).
enum G711 {
    private static let kMuLawBias: Int32 = 0x84
    private static let kMuLawClip: Int32 = 32635

    static func linearToMuLaw(_ pcm: Int16) -> UInt8 {
        var sample = Int32(pcm)
        let sign: UInt8 = sample < 0 ? 0x80 : 0x00
        if sample < 0 { sample = -sample }
        if sample > kMuLawClip { sample = kMuLawClip }
        sample += kMuLawBias

        // Find exponent (highest bit position, biased)
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while (sample & mask) == 0 && exponent > 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (sample >> (exponent + 3)) & 0x0F
        let mulaw = ~(sign | UInt8(exponent << 4) | UInt8(mantissa))
        return mulaw
    }

    static func muLawToLinear(_ ulaw: UInt8) -> Int16 {
        let u = ~ulaw
        let sign: Int32 = (u & 0x80) != 0 ? -1 : 1
        let exponent = Int32((u >> 4) & 0x07)
        let mantissa = Int32(u & 0x0F)
        let magnitude = ((mantissa << 3) + kMuLawBias) << exponent
        return Int16(clamping: sign * (magnitude - kMuLawBias))
    }

    static func linearToALaw(_ pcm: Int16) -> UInt8 {
        var sample = Int32(pcm)
        let sign: UInt8 = sample >= 0 ? 0x80 : 0x00
        if sample < 0 { sample = -sample - 1 }
        if sample > 32767 { sample = 32767 }

        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while (sample & mask) == 0 && exponent > 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa: Int32
        if exponent == 0 {
            mantissa = (sample >> 4) & 0x0F
        } else {
            mantissa = (sample >> (exponent + 3)) & 0x0F
        }
        let alaw = (sign | UInt8(exponent << 4) | UInt8(mantissa)) ^ 0x55
        return alaw
    }

    static func aLawToLinear(_ alaw: UInt8) -> Int16 {
        let a = alaw ^ 0x55
        let sign: Int32 = (a & 0x80) != 0 ? 1 : -1
        let exponent = Int32((a >> 4) & 0x07)
        let mantissa = Int32(a & 0x0F)
        var magnitude: Int32
        if exponent == 0 {
            magnitude = (mantissa << 4) + 8
        } else {
            magnitude = ((mantissa << 4) + 0x108) << (exponent - 1)
        }
        return Int16(clamping: sign * magnitude)
    }

    /// Standard "silence" byte for each codec. Sending these in RTP
    /// keeps the peer's media path open without producing audible noise.
    static func silenceByte(payloadType: UInt8) -> UInt8 {
        return payloadType == 8 ? 0xD5 : 0xFF
    }
}
