import Foundation

struct SIPCallConfig {
    var sipHost: String
    var sipPort: UInt16 = 5060
    var toURI: String = ""

    var localIP: String = ""           // auto-detected if empty
    var localSIPPort: UInt16 = 5060
    var localRTPPort: UInt16 = 10000

    var useSTUN: Bool = true
    var stunServer: String = ""        // empty → default servers

    var fromDisplay: String = "SIP Client"
    var fromUser: String = "sip-client"
    var fromHost: String = ""

    var authUser: String = ""
    var authPassword: String = ""

    var answerTimeout: TimeInterval = 30

    /// Audio codecs to advertise in the SDP offer, in preference order.
    /// The peer's answer picks one. Defaults to PCMU + PCMA for maximum
    /// compatibility.
    var codecs: [CodecKind] = [.pcmu, .pcma]

    /// SIP signalling transport. UDP, TCP, or TLS.
    var transportKind: SIPTransportKind = .udp
    /// When TLS, accept any presented server certificate. Convenient for
    /// dev / self-signed servers; not safe for production.
    var allowSelfSignedTLS: Bool = true

    /// Use SRTP for media (SDES key exchange in SDP). When true the
    /// offer's m= line uses RTP/SAVP and an a=crypto: line carries the
    /// master key. Only AES_CM_128_HMAC_SHA1_80 is supported.
    var useSRTP: Bool = false

    /// Arbitrary additional SIP headers injected into outbound INVITEs.
    var customHeaders: [SIPCustomHeader] = []
}
