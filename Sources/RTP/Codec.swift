import Foundation

/// Audio codecs we can negotiate over SIP.
///
/// Every codec emits one 20 ms RTP packet per frame. The RFC-defined RTP
/// timestamp clock is 8000 Hz for all three (G.722 has the famous RFC 3551
/// "lies-about-its-rate" wart: the audio is 16 kHz but timestamps still
/// advance at 8 kHz so 160 per packet, not 320).
enum CodecKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case pcmu  // G.711 μ-law
    case pcma  // G.711 A-law
    case g722  // G.722 sub-band ADPCM (wideband)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pcmu: return "PCMU (G.711 μ-law)"
        case .pcma: return "PCMA (G.711 A-law)"
        case .g722: return "G.722 (wideband)"
        }
    }

    /// Static RTP payload type per RFC 3551.
    var payloadType: UInt8 {
        switch self {
        case .pcmu: return 0
        case .pcma: return 8
        case .g722: return 9
        }
    }

    var rtpmapName: String {
        switch self {
        case .pcmu: return "PCMU"
        case .pcma: return "PCMA"
        case .g722: return "G722"
        }
    }

    /// RTP timestamp clock rate. 8000 for all three (RFC 3551 §4.5.2).
    var rtpClockRate: UInt32 { 8000 }

    /// Sample rate of the PCM samples consumed by the encoder.
    var inputSampleRate: Double {
        switch self {
        case .pcmu, .pcma: return 8000
        case .g722:        return 16000
        }
    }

    /// PCM samples consumed per 20 ms frame.
    var samplesPerFrame: Int {
        switch self {
        case .pcmu, .pcma: return 160
        case .g722:        return 320
        }
    }

    /// Encoded bytes per 20 ms frame.
    var bytesPerFrame: Int { 160 }

    /// RTP timestamp increment per packet. 160 for all three because the
    /// timestamp clock is 8 kHz × 20 ms = 160, even for G.722.
    var timestampAdvance: UInt32 { 160 }

    /// SDP a=rtpmap line content (after `a=rtpmap:<pt> `).
    var rtpmapLine: String { "\(rtpmapName)/\(rtpClockRate)" }

    func makeEncoder() -> CodecEncoder {
        switch self {
        case .pcmu: return PCMUEncoder()
        case .pcma: return PCMAEncoder()
        case .g722: return G722Encoder()
        }
    }

    func makeDecoder() -> CodecDecoder {
        switch self {
        case .pcmu: return PCMUDecoder()
        case .pcma: return PCMADecoder()
        case .g722: return G722Decoder()
        }
    }

    /// Match a static-PT codec offered/answered in SDP. Returns nil for
    /// payload types we don't recognise (e.g. dynamic 96+).
    static func fromStaticPayloadType(_ pt: UInt8) -> CodecKind? {
        switch pt {
        case 0: return .pcmu
        case 8: return .pcma
        case 9: return .g722
        default: return nil
        }
    }
}

protocol CodecEncoder: AnyObject {
    /// Encode exactly `samplesPerFrame` PCM samples to one RTP payload.
    func encode(pcm: [Int16]) -> Data
}

protocol CodecDecoder: AnyObject {
    /// Decode an RTP payload back to PCM samples.
    func decode(payload: Data) -> [Int16]
}

// MARK: - G.711 μ-law

final class PCMUEncoder: CodecEncoder {
    func encode(pcm: [Int16]) -> Data {
        var out = Data(count: pcm.count)
        for i in 0..<pcm.count {
            out[i] = G711.linearToMuLaw(pcm[i])
        }
        return out
    }
}

final class PCMUDecoder: CodecDecoder {
    func decode(payload: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: payload.count)
        for i in 0..<payload.count {
            out[i] = G711.muLawToLinear(payload[i])
        }
        return out
    }
}

// MARK: - G.711 A-law

final class PCMAEncoder: CodecEncoder {
    func encode(pcm: [Int16]) -> Data {
        var out = Data(count: pcm.count)
        for i in 0..<pcm.count {
            out[i] = G711.linearToALaw(pcm[i])
        }
        return out
    }
}

final class PCMADecoder: CodecDecoder {
    func decode(payload: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: payload.count)
        for i in 0..<payload.count {
            out[i] = G711.aLawToLinear(payload[i])
        }
        return out
    }
}
