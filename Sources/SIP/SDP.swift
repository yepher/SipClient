import Foundation

enum SDP {
    /// Build an audio SDP offer with G.711 μ-law (PT 0), G.711 A-law (PT 8),
    /// and telephone-event (PT 101) for DTMF.
    static func buildAudioOffer(rtpHost: String, rtpPort: UInt16) -> String {
        var s = ""
        s += "v=0\r\n"
        s += "o=sip-client 0 0 IN IP4 \(rtpHost)\r\n"
        s += "s=SIP Client Call\r\n"
        s += "c=IN IP4 \(rtpHost)\r\n"
        s += "t=0 0\r\n"
        s += "m=audio \(rtpPort) RTP/AVP 0 8 101\r\n"
        s += "a=rtpmap:0 PCMU/8000\r\n"
        s += "a=rtpmap:8 PCMA/8000\r\n"
        s += "a=rtpmap:101 telephone-event/8000\r\n"
        s += "a=fmtp:101 0-16\r\n"
        s += "a=sendrecv\r\n"
        return s
    }

    struct Answer {
        var remoteHost: String = ""
        var remotePort: UInt16 = 0
        /// Negotiated audio payload type (0 = PCMU, 8 = PCMA).
        var audioPT: UInt8 = 0
        /// Telephone-event payload type if offered, else nil.
        var dtmfPT: UInt8?
    }

    static func parseAnswer(_ body: String) -> Answer {
        var ans = Answer()
        var rtpmaps: [UInt8: String] = [:]
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
            }
        }
        for (pt, name) in rtpmaps where name.lowercased().hasPrefix("telephone-event") {
            ans.dtmfPT = pt
            break
        }
        return ans
    }
}
