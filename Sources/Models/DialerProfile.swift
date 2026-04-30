import Foundation

/// A named SIP trunk / target configuration. Stores everything the Dialer
/// needs except the auth password, which is kept only in memory.
struct DialerProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sipHost: String
    var sipPort: UInt16
    var toURI: String
    var fromUser: String
    var fromDisplay: String
    var authUser: String
    var useSTUN: Bool
    var stunServer: String
    var localSIPPort: UInt16
    var localRTPPort: UInt16
    var callDuration: Double

    /// Codecs to advertise in SDP, in preference order.
    /// Decoded with a default for older saved profiles.
    var codecs: [CodecKind] = [.pcmu, .pcma]

    /// SIP signalling transport. UDP / TCP / TLS.
    var transportKind: SIPTransportKind = .udp
    /// Accept any TLS server certificate. Convenient for dev.
    var allowSelfSignedTLS: Bool = true

    /// Use SRTP for media (SDES key exchange).
    var useSRTP: Bool = false

    /// Arbitrary additional SIP headers injected into outbound INVITEs.
    /// Empty `name` rows are ignored on the wire.
    var customHeaders: [SIPCustomHeader] = []

    init(
        id: UUID = UUID(),
        name: String,
        sipHost: String = "",
        sipPort: UInt16 = 5060,
        toURI: String = "",
        fromUser: String = "sip-client",
        fromDisplay: String = "SIP Client",
        authUser: String = "",
        useSTUN: Bool = true,
        stunServer: String = "",
        localSIPPort: UInt16 = 5060,
        localRTPPort: UInt16 = 10000,
        callDuration: Double = 30,
        codecs: [CodecKind] = [.pcmu, .pcma],
        transportKind: SIPTransportKind = .udp,
        allowSelfSignedTLS: Bool = true,
        useSRTP: Bool = false,
        customHeaders: [SIPCustomHeader] = []
    ) {
        self.id = id
        self.name = name
        self.sipHost = sipHost
        self.sipPort = sipPort
        self.toURI = toURI
        self.fromUser = fromUser
        self.fromDisplay = fromDisplay
        self.authUser = authUser
        self.useSTUN = useSTUN
        self.stunServer = stunServer
        self.localSIPPort = localSIPPort
        self.localRTPPort = localRTPPort
        self.callDuration = callDuration
        self.codecs = codecs
        self.transportKind = transportKind
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.useSRTP = useSRTP
        self.customHeaders = customHeaders
    }

    /// Custom decoder that defaults `codecs` for older saved profiles
    /// that pre-date the field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.sipHost = try c.decode(String.self, forKey: .sipHost)
        self.sipPort = try c.decode(UInt16.self, forKey: .sipPort)
        self.toURI = try c.decode(String.self, forKey: .toURI)
        self.fromUser = try c.decode(String.self, forKey: .fromUser)
        self.fromDisplay = try c.decode(String.self, forKey: .fromDisplay)
        self.authUser = try c.decode(String.self, forKey: .authUser)
        self.useSTUN = try c.decode(Bool.self, forKey: .useSTUN)
        self.stunServer = try c.decode(String.self, forKey: .stunServer)
        self.localSIPPort = try c.decode(UInt16.self, forKey: .localSIPPort)
        self.localRTPPort = try c.decode(UInt16.self, forKey: .localRTPPort)
        self.callDuration = try c.decode(Double.self, forKey: .callDuration)
        self.codecs = (try? c.decode([CodecKind].self, forKey: .codecs)) ?? [.pcmu, .pcma]
        self.transportKind = (try? c.decode(SIPTransportKind.self, forKey: .transportKind)) ?? .udp
        self.allowSelfSignedTLS = (try? c.decode(Bool.self, forKey: .allowSelfSignedTLS)) ?? true
        self.useSRTP = (try? c.decode(Bool.self, forKey: .useSRTP)) ?? false
        self.customHeaders = (try? c.decode([SIPCustomHeader].self,
                                            forKey: .customHeaders)) ?? []
    }

    func callConfig(authPassword: String) -> SIPCallConfig {
        var cfg = SIPCallConfig(sipHost: sipHost.trimmingCharacters(in: .whitespaces))
        cfg.sipPort = sipPort
        cfg.toURI = toURI.trimmingCharacters(in: .whitespaces)
        cfg.fromUser = fromUser
        cfg.fromDisplay = fromDisplay
        cfg.authUser = authUser
        cfg.authPassword = authPassword
        cfg.useSTUN = useSTUN
        cfg.stunServer = stunServer
        cfg.localSIPPort = localSIPPort
        cfg.localRTPPort = localRTPPort
        cfg.callDuration = callDuration
        cfg.codecs = codecs.isEmpty ? [.pcmu, .pcma] : codecs
        cfg.transportKind = transportKind
        cfg.allowSelfSignedTLS = allowSelfSignedTLS
        cfg.useSRTP = useSRTP
        cfg.customHeaders = customHeaders
        return cfg
    }
}
