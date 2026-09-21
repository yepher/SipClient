import Foundation
import Security

enum SDP {
    /// Assign RTP payload types to an offer's codec list. Codecs with an
    /// RFC 3551 static type keep it; the rest are handed dynamic numbers
    /// from 96 upward, skipping 101 which we reserve for telephone-event.
    static func assignPayloadTypes(_ codecs: [CodecKind]) -> [(codec: CodecKind, pt: UInt8)] {
        var out: [(codec: CodecKind, pt: UInt8)] = []
        var nextDynamic: UInt8 = 96
        for c in codecs {
            if let pt = c.staticPayloadType {
                out.append((c, pt))
            } else {
                while nextDynamic == 101 { nextDynamic &+= 1 }
                out.append((c, nextDynamic))
                nextDynamic &+= 1
            }
        }
        return out
    }

    /// Build an audio SDP offer advertising the given codec list (in
    /// preference order) plus telephone-event (PT 101) for DTMF. When
    /// `crypto` is non-nil, the m= line uses `RTP/SAVP` and an
    /// `a=crypto:` line is emitted for SDES key exchange (RFC 4568).
    static func buildAudioOffer(rtpHost: String,
                                rtpPort: UInt16,
                                codecs: [CodecKind],
                                codecParams: CodecParams = CodecParams(),
                                crypto: SDPCryptoLine? = nil) -> String {
        let list = codecs.isEmpty ? [CodecKind.pcmu, .pcma] : codecs
        let assigned = assignPayloadTypes(list)
        let pts = assigned.map { String($0.pt) }.joined(separator: " ")
        let profile = crypto != nil ? "RTP/SAVP" : "RTP/AVP"

        var s = ""
        s += "v=0\r\n"
        s += "o=sip-client 0 0 IN IP4 \(rtpHost)\r\n"
        s += "s=SIP Client Call\r\n"
        s += "c=IN IP4 \(rtpHost)\r\n"
        s += "t=0 0\r\n"
        s += "m=audio \(rtpPort) \(profile) \(pts) 101\r\n"
        for a in assigned {
            s += "a=rtpmap:\(a.pt) \(a.codec.rtpmapLine)\r\n"
            if let fmtp = a.codec.fmtpParams(codecParams) {
                s += "a=fmtp:\(a.pt) \(fmtp)\r\n"
            }
        }
        s += "a=rtpmap:101 telephone-event/8000\r\n"
        s += "a=fmtp:101 0-16\r\n"
        if let crypto {
            s += "\(crypto.sdpLine)\r\n"
        }
        s += "a=sendrecv\r\n"
        return s
    }

    struct Answer {
        var remoteHost: String = ""
        var remotePort: UInt16 = 0
        /// Negotiated audio payload type.
        var audioPT: UInt8 = 0
        /// Negotiated codec, resolved from the PT plus rtpmap entries.
        var codec: CodecKind = .pcmu
        /// Codec-specific parameters read back from `a=fmtp`. Only
        /// meaningful for AMR-WB today.
        var codecParams: CodecParams = CodecParams()
        /// Telephone-event payload type if offered, else nil.
        var dtmfPT: UInt8?
        /// Peer's SDES crypto context if the answer enabled SRTP.
        var crypto: SDPCryptoLine?
        /// Negotiated packet time in milliseconds (RFC 4566 a=ptime).
        /// Defaults to 20 ms per RFC 3551 if the answer didn't include
        /// the attribute.
        var ptime: Int = 20
    }

    static func parseAnswer(_ body: String) -> Answer {
        var ans = Answer()
        var rtpmaps: [UInt8: String] = [:]
        var fmtps: [UInt8: String] = [:]
        for line in body.components(separatedBy: "\r\n") {
            if line.hasPrefix("c=IN IP4 ") {
                ans.remoteHost = String(line.dropFirst("c=IN IP4 ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("m=audio ") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let p = UInt16(parts[1]) {
                    ans.remotePort = p
                }
                if parts.count >= 4, let pt = UInt8(parts[3]) {
                    ans.audioPT = pt
                }
            } else if line.hasPrefix("a=rtpmap:") {
                let rest = String(line.dropFirst("a=rtpmap:".count))
                let parts = rest.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pt = UInt8(parts[0]) {
                    rtpmaps[pt] = String(parts[1])
                }
            } else if line.hasPrefix("a=fmtp:") {
                let rest = String(line.dropFirst("a=fmtp:".count))
                let parts = rest.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pt = UInt8(parts[0]) {
                    fmtps[pt] = String(parts[1])
                }
            } else if line.hasPrefix("a=crypto:") {
                if ans.crypto == nil {
                    let value = String(line.dropFirst("a=crypto:".count))
                    ans.crypto = SDPCryptoLine.parse(value)
                }
            } else if line.hasPrefix("a=ptime:") {
                let raw = line.dropFirst("a=ptime:".count)
                if let n = Int(raw.trimmingCharacters(in: .whitespaces)),
                   n > 0 {
                    ans.ptime = n
                }
            }
        }
        for (pt, name) in rtpmaps where name.lowercased().hasPrefix("telephone-event") {
            ans.dtmfPT = pt
            break
        }
        // Resolve the codec: prefer rtpmap name (handles both static and
        // dynamic PTs), fall back to the static PT table.
        if let mapped = rtpmaps[ans.audioPT]?.split(separator: "/").first.map(String.init),
           let c = CodecKind.fromRTPMapName(mapped) {
            ans.codec = c
        } else if let c = CodecKind.fromStaticPayloadType(ans.audioPT) {
            ans.codec = c
        }
        if ans.codec == .amrwb {
            // RFC 4867 §8.1: octet-align defaults to 0 (bandwidth-
            // efficient) when the parameter is absent from the answer.
            ans.codecParams.amrwbOctetAligned =
                parseOctetAlign(fmtps[ans.audioPT]) ?? false
        }
        return ans
    }

    /// Pull `octet-align` out of an AMR-WB fmtp parameter string.
    /// Parameters are `;`-separated `key=value` pairs in any order, and
    /// peers vary on spacing, so both are tolerated.
    static func parseOctetAlign(_ fmtp: String?) -> Bool? {
        guard let fmtp else { return nil }
        for param in fmtp.split(separator: ";") {
            let kv = param.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "octet-align" else { continue }
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            return value == "1"
        }
        return nil
    }
}

/// SDES `a=crypto` line (RFC 4568). For now we only support
/// `AES_CM_128_HMAC_SHA1_80` (most common SRTP suite) — 30 bytes of
/// keying material (16-byte master key + 14-byte master salt) base64-
/// encoded inline. Optional `lifetime` and `MKI` parameters in the wire
/// format are parsed-and-ignored; we don't generate them.
struct SDPCryptoLine: Equatable {
    static let defaultSuite = "AES_CM_128_HMAC_SHA1_80"

    var tag: Int
    var suite: String
    var masterKey: Data    // 16 bytes
    var masterSalt: Data   // 14 bytes

    /// Generate a fresh offer with a random master key + salt.
    static func random(tag: Int = 1) -> SDPCryptoLine {
        var bytes = Data(count: 30)
        _ = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 30, ptr.baseAddress!)
        }
        return SDPCryptoLine(
            tag: tag,
            suite: defaultSuite,
            masterKey: Data(bytes.prefix(16)),
            masterSalt: Data(bytes.suffix(from: 16))
        )
    }

    var sdpLine: String {
        var combined = masterKey
        combined.append(masterSalt)
        return "a=crypto:\(tag) \(suite) inline:\(combined.base64EncodedString())"
    }

    /// Parse the value after `a=crypto:` — `<tag> <suite> inline:<b64>[|...]`.
    static func parse(_ value: String) -> SDPCryptoLine? {
        let parts = value.split(separator: " ")
        guard parts.count >= 3,
              let tag = Int(parts[0])
        else { return nil }
        let suite = String(parts[1])
        // The third token is the keying material; it may be followed by
        // additional whitespace-separated session params we don't use.
        let keyParam = String(parts[2])
        guard keyParam.hasPrefix("inline:") else { return nil }
        let after = keyParam.dropFirst("inline:".count)
        // The keying material itself can have optional `|lifetime|MKI`
        // suffixes; the actual base64 ends at the first `|`.
        let keyB64 = String(after.split(separator: "|").first ?? "")
        guard let combined = Data(base64Encoded: keyB64),
              combined.count >= 30
        else { return nil }
        return SDPCryptoLine(
            tag: tag,
            suite: suite,
            masterKey: Data(combined.prefix(16)),
            masterSalt: combined.subdata(in: 16..<30)
        )
    }
}
