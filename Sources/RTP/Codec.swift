import Foundation

/// Audio codecs we can negotiate over SIP.
///
/// Every codec emits one 20 ms RTP packet per frame, but very little else
/// is uniform between them, which is why the properties below are all
/// switches rather than constants:
///
///   * G.711 is 8 kHz narrowband on an 8 kHz RTP clock.
///   * G.722 carries 16 kHz audio but keeps an 8 kHz RTP clock — the
///     RFC 3551 §4.5.2 "lies about its rate" wart — so its timestamp
///     still advances 160 per packet, not 320.
///   * AMR-WB carries 16 kHz audio on a genuine 16 kHz RTP clock
///     (RFC 4867), so it advances 320, needs a dynamically negotiated
///     payload type, and has a frame size that varies with bitrate mode.
enum CodecKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case pcmu   // G.711 μ-law
    case pcma   // G.711 A-law
    case g722   // G.722 sub-band ADPCM (wideband)
    case amrwb  // AMR-WB / G.722.2 (wideband)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pcmu:  return "PCMU (G.711 μ-law)"
        case .pcma:  return "PCMA (G.711 A-law)"
        case .g722:  return "G.722 (wideband)"
        case .amrwb: return "AMR-WB (G.722.2, wideband)"
        }
    }

    /// Static RTP payload type per RFC 3551, or nil for codecs that must
    /// be given a dynamic type (96+) during negotiation. `SDP` assigns
    /// those when building an offer.
    var staticPayloadType: UInt8? {
        switch self {
        case .pcmu:  return 0
        case .pcma:  return 8
        case .g722:  return 9
        case .amrwb: return nil
        }
    }

    var rtpmapName: String {
        switch self {
        case .pcmu:  return "PCMU"
        case .pcma:  return "PCMA"
        case .g722:  return "G722"
        case .amrwb: return "AMR-WB"
        }
    }

    /// RTP timestamp clock rate, as written in `a=rtpmap`. 8000 for the
    /// G.711 pair and — deliberately — for G.722; 16000 for AMR-WB.
    var rtpClockRate: UInt32 {
        switch self {
        case .pcmu, .pcma, .g722: return 8000
        case .amrwb:              return 16000
        }
    }

    /// Sample rate of the PCM samples consumed by the encoder.
    var inputSampleRate: Double {
        switch self {
        case .pcmu, .pcma:   return 8000
        case .g722, .amrwb:  return 16000
        }
    }

    /// PCM samples consumed per 20 ms frame.
    var samplesPerFrame: Int {
        switch self {
        case .pcmu, .pcma:   return 160
        case .g722, .amrwb:  return 320
        }
    }

    /// RTP timestamp increment per 20 ms packet: clock rate × 0.020.
    var timestampAdvance: UInt32 {
        switch self {
        case .pcmu, .pcma, .g722: return 160
        case .amrwb:              return 320
        }
    }

    /// SDP `a=rtpmap` line content (everything after `a=rtpmap:<pt> `).
    var rtpmapLine: String { "\(rtpmapName)/\(rtpClockRate)" }

    /// SDP `a=fmtp` parameters for this codec, or nil when it needs none.
    /// We state `octet-align` explicitly in both directions: RFC 4867
    /// defaults to bandwidth-efficient when the parameter is absent, and
    /// for a test client it's far better to see the intent on the wire
    /// than to rely on a default.
    func fmtpParams(_ params: CodecParams) -> String? {
        switch self {
        case .pcmu, .pcma, .g722:
            return nil
        case .amrwb:
            return "octet-align=\(params.amrwbOctetAligned ? 1 : 0)"
        }
    }

    func makeEncoder(params: CodecParams = CodecParams()) -> CodecEncoder {
        switch self {
        case .pcmu:  return PCMUEncoder()
        case .pcma:  return PCMAEncoder()
        case .g722:  return G722Encoder()
        case .amrwb: return AMRWBEncoder(mode: params.amrwbMode,
                                         octetAligned: params.amrwbOctetAligned)
        }
    }

    func makeDecoder(params: CodecParams = CodecParams()) -> CodecDecoder {
        switch self {
        case .pcmu:  return PCMUDecoder()
        case .pcma:  return PCMADecoder()
        case .g722:  return G722Decoder()
        case .amrwb: return AMRWBDecoder(octetAligned: params.amrwbOctetAligned)
        }
    }

    /// Match a static-PT codec offered/answered in SDP. Returns nil for
    /// payload types we don't recognise (e.g. dynamic 96+, which are
    /// resolved by rtpmap name instead).
    static func fromStaticPayloadType(_ pt: UInt8) -> CodecKind? {
        switch pt {
        case 0: return .pcmu
        case 8: return .pcma
        case 9: return .g722
        default: return nil
        }
    }

    /// Match a codec by the encoding name in an `a=rtpmap` line. Case
    /// insensitive, since peers are inconsistent about "AMR-WB".
    static func fromRTPMapName(_ name: String) -> CodecKind? {
        switch name.uppercased() {
        case "PCMU":   return .pcmu
        case "PCMA":   return .pcma
        case "G722":   return .g722
        case "AMR-WB": return .amrwb
        default:       return nil
        }
    }
}

/// Codec-specific negotiated parameters. Only AMR-WB uses these today;
/// the G.711 pair and G.722 have nothing to configure.
struct CodecParams: Equatable, Hashable {
    /// Bitrate mode we *encode* at. The peer may send us any mode; the
    /// decoder reads the mode per frame from the payload.
    var amrwbMode: AMRWBMode = .k1265
    /// RFC 4867 payload framing. True = octet-aligned (`octet-align=1`),
    /// false = bandwidth-efficient, which is what most carriers use.
    var amrwbOctetAligned: Bool = true
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
